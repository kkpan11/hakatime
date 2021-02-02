{-# LANGUAGE TemplateHaskell #-}

module Haka.Import
  ( API,
    server,
    handleImportRequest,
  )
where

import Control.Exception.Safe (Exception, Typeable, bracket, throw)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as Bs
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime (..))
import GHC.Generics
import Haka.AesonHelpers (noPrefixOptions)
import qualified Haka.Cli as Cli
import qualified Haka.DatabaseOperations as DbOps
import qualified Haka.Errors as Err
import Haka.Types (ApiToken, AppCtx (..), AppM, EntityType (..), HeartbeatPayload (..), runAppT)
import Haka.Utils (genDateRange)
import qualified Hasql.Connection as HasqlConn
import qualified Hasql.Decoders as D
import qualified Hasql.Encoders as E
import qualified Hasql.Queue.Low.AtLeastOnce as HasqlQueue
import Katip
import Network.HTTP.Req ((/:), (=:))
import qualified Network.HTTP.Req as R
import Polysemy (runM)
import Polysemy.Error (runError)
import Polysemy.IO (embedToMonadIO)
import Servant

data JobStatus
  = JobSubmitted
  | JobPending
  | JobFailed
  | JobFinished
  deriving (Generic, Show)

instance A.ToJSON JobStatus

newtype ImportRequestResponse = ImportRequestResponse
  { jobStatus :: JobStatus
  }
  deriving (Generic, Show)

instance A.ToJSON ImportRequestResponse

data QueueItem = QueueItem
  { reqPayload :: ImportRequestPayload,
    requester :: Text
  }
  deriving (Generic, Show)

instance A.FromJSON QueueItem

instance A.ToJSON QueueItem

data ImportRequestPayload = ImportRequestPayload
  { apiToken :: Text,
    startDate :: UTCTime,
    endDate :: UTCTime
  }
  deriving (Generic, Show)

instance A.FromJSON ImportRequestPayload

instance A.ToJSON ImportRequestPayload

queueName :: Text
queueName = "_import_requests_queue_channel"

wakatimeApi :: Text
wakatimeApi = "api.wakatime.com"

data ImportHeartbeatPayload = ImportHeartbeatPayload
  { wMachine_name_id :: Maybe Text,
    wUser_agent_id :: Text,
    wBranch :: Maybe Text,
    wCategory :: Maybe Text,
    wCursorpos :: Maybe Text,
    wDependencies :: Maybe [Text],
    wEntity :: Text,
    wIs_write :: Maybe Bool,
    wLanguage :: Maybe Text,
    wLineno :: Maybe Text,
    wLines :: Maybe Int64,
    wProject :: Maybe Text,
    wType :: EntityType,
    wTime :: Double
  }
  deriving (Eq, Show, Generic)

data HeartbeatList = HeartbeatList
  { listData :: [ImportHeartbeatPayload],
    listStart :: UTCTime,
    listEnd :: UTCTime,
    listTimezone :: Text
  }
  deriving (Show, Generic)

instance A.FromJSON ImportHeartbeatPayload where
  parseJSON = A.genericParseJSON noPrefixOptions

instance A.FromJSON HeartbeatList where
  parseJSON = A.genericParseJSON noPrefixOptions

data UserAgentPayload = UserAgentPayload
  { uaId :: Text,
    uaValue :: Text
  }
  deriving (Show, Generic)

newtype UserAgentList = UserAgentList
  { uaData :: [UserAgentPayload]
  }
  deriving (Show, Generic)

instance A.FromJSON UserAgentPayload where
  parseJSON = A.genericParseJSON noPrefixOptions

instance A.FromJSON UserAgentList where
  parseJSON = A.genericParseJSON noPrefixOptions

process :: QueueItem -> AppM ()
process item = do
  $(logTM) InfoS ("processing import request for user: " <> showLS (requester item))

  let payload = reqPayload item
      header = R.header "Authorization" ("Basic " <> encodeUtf8 (apiToken payload))
      allDays = genDateRange (startDate payload) (endDate payload)

  uaRes <-
    R.req
      R.GET
      (R.https wakatimeApi /: "api" /: "v1" /: "users" /: "current" /: "user_agents")
      R.NoReqBody
      R.jsonResponse
      header

  let userAgents = (R.responseBody uaRes :: UserAgentList)

  traverse_
    ( \day -> do
        heartbeatsRes <-
          R.req
            R.GET
            (R.https wakatimeApi /: "api" /: "v1" /: "users" /: "current" /: "heartbeats")
            R.NoReqBody
            R.jsonResponse
            (("date" =: day) <> header)

        let heartbeatList = (R.responseBody heartbeatsRes :: HeartbeatList)

        $(logTM) InfoS ("importing " <> showLS (length $ listData heartbeatList) <> " heartbeats for day " <> showLS day)

        let heartbeats =
              convertForDb
                (requester item)
                (uaData userAgents)
                (listData heartbeatList)

        pool' <- asks pool

        res <-
          runM
            . embedToMonadIO
            . runError
            $ DbOps.interpretDatabaseIO $
              DbOps.importHeartbeats pool' (requester item) (Just "wakatime-import") heartbeats

        either Err.logError pure res
    )
    allDays

  $(logTM) InfoS "import completed"

convertForDb :: Text -> [UserAgentPayload] -> [ImportHeartbeatPayload] -> [HeartbeatPayload]
convertForDb user userAgents = map convertSchema
  where
    convertSchema payload =
      let userAgentValue = uaValue $ head $ filter (\x -> uaId x == wUser_agent_id payload) userAgents
       in HeartbeatPayload
            { branch = wBranch payload,
              category = wCategory payload,
              cursorpos = wCursorpos payload,
              dependencies = wDependencies payload,
              editor = Nothing,
              plugin = Nothing,
              platform = Nothing,
              machine = Nothing,
              entity = wEntity payload,
              file_lines = wLines payload,
              is_write = wIs_write payload,
              language = wLanguage payload,
              lineno = wLineno payload,
              project = wProject payload,
              user_agent = userAgentValue,
              sender = Just user,
              time_sent = wTime payload,
              ty = wType payload
            }

data ImportRequestException
  = ConnectionError (Maybe Bs.ByteString)
  | InvalidToken String
  | MalformedPaylod String
  deriving (Show, Typeable)

instance Exception ImportRequestException

handleImportRequest :: AppM ()
handleImportRequest = do
  settings <- liftIO Cli.getDbSettings
  ctx <- ask

  liftIO $
    bracket
      (acquireConn settings)
      HasqlConn.release
      ( \conn -> do
          liftIO $
            HasqlQueue.withDequeue
              queueName
              conn
              D.json
              numRetries
              numItems
              (processItems ctx)
      )
  where
    acquireConn settings = do
      res <- liftIO $ HasqlConn.acquire settings
      case res of
        Left e -> throw $ ConnectionError e
        Right conn -> pure conn

    processItems ctx items = do
      if null items
        then throw $ MalformedPaylod "Received empty payload list"
        else do
          case A.fromJSON (head items) :: A.Result QueueItem of
            A.Success item -> runAppT ctx $ process item
            A.Error e -> throw $ MalformedPaylod e

    numRetries :: Int
    numRetries = 3

    numItems :: Int
    numItems = 1

type API = ImportRequest :<|> ImportRequestStatus

type ImportRequest =
  "import"
    :> Header "Authorization" ApiToken
    :> ReqBody '[JSON] ImportRequestPayload
    :> Post '[JSON] ImportRequestResponse

type ImportRequestStatus =
  "import" :> "status"
    :> Header "Authorization" ApiToken
    :> ReqBody '[JSON] ImportRequestPayload
    :> Post '[JSON] ImportRequestResponse

enqueueRequest :: A.Value -> IO ()
enqueueRequest payload = do
  settings <- Cli.getDbSettings
  res <- HasqlConn.acquire settings

  case res of
    Left Nothing -> error "failed to acquire connection while enqueuing import request"
    Left (Just e) -> error $ Bs.unpack e
    Right conn -> HasqlQueue.enqueue queueName conn E.json [payload]

server ::
  ( Maybe ApiToken ->
    ImportRequestPayload ->
    AppM ImportRequestResponse
  )
    :<|> ( Maybe ApiToken ->
           ImportRequestPayload ->
           AppM ImportRequestResponse
         )
server = importRequestHandler :<|> checkRequestStatusHandler

checkRequestStatusHandler :: Maybe ApiToken -> ImportRequestPayload -> AppM ImportRequestResponse
checkRequestStatusHandler Nothing _ = throw Err.missingAuthError
checkRequestStatusHandler (Just token) payload = do
  p <- asks pool

  res <-
    runM
      . embedToMonadIO
      . runError
      $ DbOps.interpretDatabaseIO $
        DbOps.getUserByToken p token

  user <- either Err.logError pure res

  $(logTM) InfoS ("checking pending import request for user: " <> showLS user)

  let item =
        A.toJSON $
          QueueItem
            { requester = user,
              reqPayload = payload
            }

  statusResult <-
    runM
      . embedToMonadIO
      . runError
      $ DbOps.interpretDatabaseIO $
        DbOps.getJobStatus p item

  status <- either Err.logError pure statusResult

  return $
    ImportRequestResponse
      { jobStatus =
          case status of
            Nothing -> JobFinished
            Just s -> if s == "failed" then JobFailed else JobPending
      }

importRequestHandler :: Maybe ApiToken -> ImportRequestPayload -> AppM ImportRequestResponse
importRequestHandler Nothing _ = throw Err.missingAuthError
importRequestHandler (Just token) payload = do
  p <- asks pool

  userResult <-
    runM
      . embedToMonadIO
      . runError
      $ DbOps.interpretDatabaseIO $
        DbOps.getUserByToken p token

  user <- either Err.logError pure userResult

  $(logTM) InfoS ("received an import request from user: " <> showLS user)

  let item =
        A.toJSON $
          QueueItem
            { requester = user,
              reqPayload = payload
            }

  -- Delete previous failed jobs with the same parameters.
  affectedRows <-
    runM
      . embedToMonadIO
      . runError
      $ DbOps.interpretDatabaseIO $
        DbOps.deleteFailedJobs p item

  _ <- either Err.logError pure affectedRows

  liftIO $ enqueueRequest item

  return $
    ImportRequestResponse
      { jobStatus = JobSubmitted
      }