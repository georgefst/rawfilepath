module System.Process.RawFilePath
    ( proc
    , setStdin
    , setStdout
    , setStderr

    , startProcess
    , stopProcess
    , terminateProcess
    , waitForProcess

    , processStdin
    , processStdout
    , processStderr

    , CreatePipe(..)
    , Inherit(..)
    , NoStream(..)
    , UseHandle(..)
    ) where

-- base modules

import RawFilePath.Import hiding (ClosedHandle)

-- local modules

import System.Process.RawFilePath.Common
import System.Process.RawFilePath.Internal
import System.Process.RawFilePath.Posix

proc :: RawFilePath -> [ByteString] -> ProcessConf Inherit Inherit Inherit
proc cmd args = ProcessConf
    { cmdargs = cmd : args
    , cwd = Nothing
    , env = Nothing
    , cfgStdin = Inherit
    , cfgStdout = Inherit
    , cfgStderr = Inherit
    , closeFds = False
    , createGroup = False
    , delegateCtlc = False
    , createNewConsole = False
    , newSession = False
    , childGroup = Nothing
    , childUser = Nothing
    }

setStdin
    :: (StreamSpec newStdin)
    => ProcessConf oldStdin stdout stderr
    -> newStdin
    -> ProcessConf newStdin stdout stderr
setStdin p newStdin = p { cfgStdin = newStdin }
infix 4 `setStdin`

setStdout
    :: (StreamSpec newStdout)
    => ProcessConf stdin oldStdout stderr
    -> newStdout
    -> ProcessConf stdin newStdout stderr
setStdout p newStdout = p { cfgStdout = newStdout }
infix 4 `setStdout`

setStderr
    :: (StreamSpec newStderr)
    => ProcessConf stdin stdout oldStderr
    -> newStderr
    -> ProcessConf stdin stdout newStderr
setStderr p newStderr = p { cfgStderr = newStderr }
infix 4 `setStderr`

startProcess
    :: (StreamSpec stdin, StreamSpec stdout, StreamSpec stderr)
    => ProcessConf stdin stdout stderr
    -> IO (Process stdin stdout stderr)
startProcess = createProcessInternal

stopProcess :: Process stdin stdout stderr -> IO ExitCode
stopProcess p = do
    terminateProcess p
    waitForProcess p

waitForProcess
  :: Process stdin stdout stderr
  -> IO ExitCode
waitForProcess ph = lockWaitpid $ do
  p_ <- modifyProcessHandle ph $ \ p_ -> return (p_,p_)
  case p_ of
    ClosedHandle e -> return e
    OpenHandle h  -> do
        e <- alloca $ \ pret -> do
          -- don't hold the MVar while we call c_waitForProcess...
          throwErrnoIfMinus1Retry_ "waitForProcess" (c_waitForProcess h pret)
          modifyProcessHandle ph $ \ p_' ->
            case p_' of
              ClosedHandle e  -> return (p_', e)
              OpenExtHandle{} -> return (p_', ExitFailure (-1))
              OpenHandle ph'  -> do
                closePHANDLE ph'
                code <- peek pret
                let e = if code == 0
                       then ExitSuccess
                       else ExitFailure (fromIntegral code)
                return (ClosedHandle e, e)
        when delegatingCtlc $
          endDelegateControlC e
        return e
    OpenExtHandle _ _job _iocp ->
        return $ ExitFailure (-1)
  where
    -- If more than one thread calls `waitpid` at a time, `waitpid` will
    -- return the exit code to one of them and (-1) to the rest of them,
    -- causing an exception to be thrown.
    -- Cf. https://github.com/haskell/process/issues/46, and
    -- https://github.com/haskell/process/pull/58 for further discussion
    lockWaitpid m = withMVar (waitpidLock ph) $ \ () -> m
    delegatingCtlc = mbDelegateCtlc ph

terminateProcess :: Process stdin stdout stderr -> IO ()
terminateProcess p = withProcessHandle p $ \ case
    ClosedHandle  _ -> return ()
    OpenExtHandle{} -> error
        "terminateProcess with OpenExtHandle should not happen on POSIX."
    OpenHandle    h -> do
        throwErrnoIfMinus1Retry_ "terminateProcess" $ c_terminateProcess h
        return ()
        -- does not close the handle, we might want to try terminating it
        -- again, or get its exit code.