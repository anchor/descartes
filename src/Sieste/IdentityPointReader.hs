--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE InstanceSigs #-}

module Sieste.IdentityPointReader
(
) where

import Control.Monad.Identity
import Data.ReinterpretCast
import Marquise.Client
import Pipes
import Sieste.Classes

instance PointReader Identity where
    -- Address for Ints
    readPoints 0 start end _ =
        forM_ [start, end `div` 128..end] $ \n ->
            yield (SimplePoint 0 n (n + 1))

    -- Address for Doubles
    readPoints 1 start end _ = do
        yield (SimplePoint 0 start (doubleToWord 0.0))
        let mid = (start + end) `div` 2
        yield (SimplePoint 0 mid (doubleToWord 1.1))
        yield (SimplePoint 0 end (doubleToWord 2.2))

    readPoints _ _ _ _ = error "invalid address, expect 0 (for ints) or 1 (for doubles)"
