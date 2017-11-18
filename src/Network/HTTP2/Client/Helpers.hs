{-# LANGUAGE OverloadedStrings #-}

-- | A toolbox with high-level functions to interact with an established HTTP2
-- conection.
--
-- These helpers make the assumption that you want to work in a multi-threaded
-- environment and that you want to send and receiving whole HTTP requests at
-- once (i.e., you do not care about streaming individual HTTP
-- requests/responses but want to make many requests).
module Network.HTTP2.Client.Helpers (
  -- * Sending and receiving HTTP body
    upload
  , waitStream
  , fromStreamResult 
  , StreamResult
  , StreamResponse
  -- * Diagnostics
  , ping
  , TimedOut
  , PingReply
  ) where

import           Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Network.HTTP2 as HTTP2
import qualified Network.HPACK as HPACK
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (race)

import Network.HTTP2.Client

-- | Opaque type to express an action which timed out.
data TimedOut = TimedOut
  deriving Show

-- | Result for a 'ping'.
type PingReply = (UTCTime, UTCTime, Either TimedOut (HTTP2.FrameHeader, HTTP2.FramePayload))

-- | Performs a 'ping' and waits for a reply up to a given timeout (in
-- microseconds).
ping :: Http2Client
     -- ^ client connection
     -> Int
     -- ^ timeout in microseconds
     -> ByteString
     -- ^ 8-bytes message to uniquely identify the reply
     -> IO PingReply
ping conn timeout msg = do
    t0 <- getCurrentTime
    waitPing <- _ping conn msg
    pingReply <- race (threadDelay timeout >> return TimedOut) waitPing
    t1 <- getCurrentTime
    return $ (t0, t1, pingReply)

-- | Result containing the unpacked headers and all frames received in on a
-- stream. See 'StreamResponse' and 'fromStreamResult' to get a higher-level
-- utility.
type StreamResult = (Either HTTP2.ErrorCode HPACK.HeaderList, [Either HTTP2.ErrorCode ByteString], Maybe HPACK.HeaderList)

-- | An HTTP2 response, once fully received, is made of headers and a payload.
type StreamResponse = (HPACK.HeaderList, ByteString, Maybe HPACK.HeaderList)

-- | Uploads a whole HTTP body at a time.
--
-- This function should be called at most once per stream.  This function
-- closes the stream with HTTP2.setEndStream chunk at the end.  If you want to
-- post data (e.g., streamed chunks) your way to avoid loading a whole
-- bytestring in RAM, please study the source code of this function first.
--
-- This function sends one chunk at a time respecting by preference:
-- - server's flow control desires
-- - server's chunking preference
--
-- Uploading an empty bytestring will send a single DATA frame with
-- setEndStream and no payload.
upload :: ByteString
       -- ^ HTTP body.
       -> (HTTP2.FrameFlags -> HTTP2.FrameFlags)
       -- ^ Flag modifier for the last DATA frame sent.
       -> Http2Client
       -- ^ The client.
       -> OutgoingFlowControl
       -- ^ The outgoing flow control for this client. (We might remove this
       -- argument in the future because we can get it from the previous
       -- argument.
       -> Http2Stream
       -- ^ The corresponding HTTP stream.
       -> OutgoingFlowControl
       -- ^ The flow control for this stream.
       -> IO ()
upload "" flagmod conn _ stream _ = do
    sendData conn stream flagmod ""
upload dat flagmod conn connectionFlowControl stream streamFlowControl = do
    let wanted = ByteString.length dat

    gotStream <- _withdrawCredit streamFlowControl wanted
    got       <- _withdrawCredit connectionFlowControl gotStream
    -- Recredit the stream flow control with the excedent we cannot spend on
    -- the connection.
    _receiveCredit streamFlowControl (gotStream - got)

    let uploadChunks flagMod =
            sendData conn stream flagMod (ByteString.take got dat)

    if got == wanted
    then
        uploadChunks flagmod
    else do
        uploadChunks id
        upload (ByteString.drop got dat) flagmod conn connectionFlowControl stream streamFlowControl

-- | Wait for a stream until completion.
--
-- This function is fine if you don't want to consume results in chunks.  See
-- 'fromStreamResult' to collect the complicated 'StreamResult' into a simpler
-- 'StramResponse'.
waitStream :: Http2Stream
           -> IncomingFlowControl
           -> PushPromiseHandler
           -> IO StreamResult
waitStream stream streamFlowControl ppHandler = do
    ev <- _waitEvent stream
    case ev of
        StreamHeadersEvent _ hdrs -> do
            (dfrms,trls) <- waitDataFrames []
            return (Right hdrs, reverse dfrms, trls)
        StreamPushPromiseEvent _ ppSid ppHdrs -> do
            _handlePushPromise stream ppSid ppHdrs ppHandler
            waitStream stream streamFlowControl ppHandler
        _ ->
            error $ "expecting StreamHeadersEvent but got " ++ show ev
  where
    waitDataFrames xs = do
        ev <- _waitEvent stream
        case ev of
            StreamDataEvent fh x
                | HTTP2.testEndStream (HTTP2.flags fh) ->
                    return ((Right x):xs, Nothing)
                | otherwise                            -> do
                    _ <- _consumeCredit streamFlowControl (HTTP2.payloadLength fh)
                    _addCredit streamFlowControl (HTTP2.payloadLength fh)
                    _ <- _updateWindow $ streamFlowControl
                    waitDataFrames ((Right x):xs)
            StreamPushPromiseEvent _ ppSid ppHdrs -> do
                _handlePushPromise stream ppSid ppHdrs ppHandler
                waitDataFrames xs
            StreamHeadersEvent _ hdrs ->
                return (xs, Just hdrs)
            _ ->
                error $ "expecting StreamDataEvent but got " ++ show ev

-- | Converts a StreamResult to a StramResponse, stopping at the first error
-- using the `Either HTTP2.ErrorCode` monad.
fromStreamResult :: StreamResult -> Either HTTP2.ErrorCode StreamResponse
fromStreamResult (headersE, chunksE, trls) = do
    hdrs <- headersE
    chunks <- sequence chunksE
    return (hdrs, mconcat chunks, trls)
