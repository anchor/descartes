{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Descartes.Interpolated where

import           Control.Concurrent           hiding (yield)
import           Control.Monad.IO.Class
import           Data.ByteString.Lazy.Builder (stringUtf8)
import           Data.Maybe                   (fromJust)
import           Data.ProtocolBuffers         (getField)
import           Data.Word                    (Word64)
import           Descartes.Types.ReaderD      (DataFrame (..), RangeQuery (..),
                                               ValueType (..))
import           Descartes.Util
import           Pipes
import           Pipes.Concurrent
import           Snap.Core

interpolated :: MVar RangeQuery -> Snap ()
interpolated readerd_mvar = do
    -- The reader daemon provides no timestamp sorting within a chunk, but will
    -- provide sorting between chunks.
    --
    -- This means that the latest point (chronologically) in a burst will be no
    -- later than the first point in the next burst.
    --
    -- This allows us to stream the data the user chunk by chunk.


    tags <- getParam "source" >>= (\s -> case s of
        Just bs -> utf8Or400 bs >>= tagsOr400
        Nothing -> writeError 400 $ stringUtf8 "Must specify 'source'")

    end <- getParam "end"
        >>= validateW64 (> 0) "end must be > 0" timeNow

    start <- getParam "start"
          >>= validateW64 (< end) "start must be < end" (return $ end - 86400)

    interval <- getParam "interval"
             >>= validateW64 (> 0)  "interval must be > 0" (return $ fromEpoch 60)

    origin' <- getParam "origin" >>= (\o -> case o of
        Just bs -> utf8Or400 bs
        Nothing -> writeError 400 $ stringUtf8 "Must specify 'origin'")

    input <- liftIO $ do
        (output, input) <- spawn Single
        putMVar readerd_mvar $ RangeQuery tags start end origin' output
        return input

    modifyResponse $ setContentType "application/json"
    writeBS "["
    runEffect $ for (fromInput input
                     >-> logExceptions
                     >-> extractBursts
                     >-> interpolate interval (fromIntegral start) (fromIntegral end)
                     >-> jsonEncode
                     >-> addCommas True)
                    (lift . writeLBS)
    writeBS "]"

-- It would be nice to move error out of this to the type level.
getRational :: DataFrame -> Rational
getRational DataFrame{..}
    | getField payload == NUMBER = toRational $ fromJust $ getField valueNumeric
    | getField payload == REAL   = toRational $ fromJust $ getField valueMeasurement
    | otherwise                  = error $ "Data frame not representable as "
                                   ++ "a rational number, this is a bug."

-- Transfer control between interpolation method if the type is not
-- representable. This must be kept in sync with the getRational function above
-- until a type level solution can be devised that is not as clunky as
-- wrapping.
tryAwaitRationalBurst, tryAwaitCounterBurst
    :: Word64
    -> Word64
    -> Word64
    -> (DataFrame -> Pipe DataFrame (Int, Double) Snap ())
    -> Pipe DataFrame (Int, Double) Snap ()
tryAwaitRationalBurst interval now end k = do
    frame <- await
    case getField $ payload frame of
        NUMBER -> k frame
        REAL   -> k frame
        -- Continue as a counter
        _      -> count interval now end 0 frame

tryAwaitCounterBurst interval now end k = do
    frame <- await
    case getField $ payload frame of
        NUMBER -> interpolate interval now end
        REAL   -> interpolate interval now end
        _      -> k frame

count :: Word64
      -> Word64
      -> Word64
      -> Integer
      -> DataFrame
      -> Pipe DataFrame (Int, Double) Snap ()
count interval now end !ctr frame
    | pointTime frame > end =
        -- Done, output any values accumulated between now and end
        yield (toEpoch end, fromIntegral ctr)
    | pointTime frame >= now = do
        -- Yield our conter of values up until 'now', starting again with a new
        -- now and counter.
        yield (toEpoch (now + interval), fromIntegral ctr)
        count interval (now + interval) end 0 frame
    | pointTime frame < now =
        -- Count any frames that are not past 'now'
        tryAwaitCounterBurst interval now end
                             (count interval now end (succ ctr))
    -- Please ensure this is always impossible, currently this is caught by
    -- pointTime frame < now and pointTime frame >= now
    | otherwise = error "count: impossible"

-- This pipe takes DataFrames as input, interpolating between the values to
-- output interpolated x,y tuples at given intervals, from now to end.
--
-- Control can transfer to count in the case of tryAwaitRationalBurst not
-- getting a rational.
interpolate :: Word64 -> Word64 -> Word64
            -> Pipe DataFrame (Int, Double) Snap ()
interpolate interval now end
    | interval <= 0 = error "interval <= 0"
    | now > end = error "now > end"
    | otherwise = tryAwaitRationalBurst interval now end (emitAt now Nothing)
  where
    emitAt :: Word64    -- ^ The current requested time
           -> Maybe DataFrame -- ^ Maybe the next data point, to allow
                              --   multiple interpolated values between points
           -> DataFrame -- ^ The last known data point, initially the first.
           -> Pipe DataFrame (Int, Double) Snap ()
    emitAt t maybe_next p
        | t > end = return () -- could yield lerped at end here
        | p_time <- pointTime p
        , p_time <= t =
            case maybe_next of
                Just p' -> do
                    let p'_time = pointTime p'
                    -- Our first point is behind the requested time, which
                    -- means that If the next point is beyond the
                    -- requested_time, we can interpolate its value. If not, we
                    -- need to look further forward in the list
                    if p'_time >= t
                        then do
                            -- Obviously we have a match now and we can emit
                            -- this value. We go for Rational precision here as
                            -- we may be dealing with Word64s and I'm not sure
                            -- what kind of use cases we are dealing with.
                            --
                            -- If this turns out to be slow, we can use
                            -- Doubles.
                            let smalld = toRational $ p'_time - p_time
                            let bigd   = toRational $ p'_time - t
                            let alpha | p'_time == t = 0
                                    | p_time  == t = 1
                                    | otherwise    = bigd / smalld
                            let lerped = lerp (getRational p')
                                              (getRational p)
                                              alpha
                            yield (toEpoch t, fromRational lerped)

                            -- Now look for the next interval, we must keep the
                            -- current point in case we have to 'invent'
                            -- several interpolated points between this one and
                            -- the next.
                            emitAt (t + interval) (Just p') p
                        else
                            -- Seek forward
                            emitAt t Nothing p'
                Nothing ->
                    tryAwaitRationalBurst interval now end
                                          (\new -> emitAt t (Just new) p)
        | p_time <- pointTime p, p_time > t =
            -- Our point is ahead of the requested time, this should only
            -- happen once: initially. We catch up in one iteration by
            -- calculating the next valid interval given this first point.
            let first = ((p_time `div` interval) + 1) * interval in
                emitAt first Nothing p
        | otherwise = error "emitAt: impossible"


lerp :: Rational -> Rational -> Rational -> Rational
lerp a b alpha = ((1.0 - alpha) * a) + (alpha * b)
