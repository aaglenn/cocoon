{-
Copyrights (c) 2016. Samsung Electronics Ltd. All right reserved. 

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}
{-# LANGUAGE FlexibleContexts #-}

module Util where

import Data.Graph.Inductive
import Control.Monad.Except
import Data.List
import Data.Maybe
import Data.Bits

import Pos
import Name 

if' :: Bool -> a -> a -> a
if' True  x _ = x
if' False _ y = y

err :: (MonadError String me) => Pos -> String -> me a
err p e = throwError $ spos p ++ ": " ++ e

assert :: (MonadError String me) => Bool -> Pos -> String -> me ()
assert b p m = 
    if b 
       then return ()
       else err p m

-- Tuples
mapFst :: (a -> b) -> (a, c) -> (b, c)
mapFst f (x,y) = (f x,y)
mapSnd :: (a -> b) -> (c, a) -> (c, b)
mapSnd f (x,y) = (x,f y)

-- Check for duplicate declarations
uniq :: (MonadError String me, WithPos a, Ord b) => (a -> b) -> (a -> String) -> [a] -> me ()
uniq = uniq' pos

uniq' :: (MonadError String me, Ord b) => (a -> Pos) -> (a -> b) -> (a -> String) -> [a] -> me ()
uniq' fpos ford msgfunc xs = do
    case filter ((>1) . length) $ groupBy (\x1 x2 -> compare (ford x1) (ford x2) == EQ)  
                                $ sortBy (\x1 x2 -> compare (ford x1) (ford x2)) xs of
         g@(x:_):_ -> err (fpos x) $ msgfunc x ++ " at the following locations:\n  " ++ (intercalate "\n  " $ map (spos . fpos) g)
         _         -> return ()

uniqNames :: (MonadError String me, WithPos a, WithName a) => (String -> String) -> [a] -> me ()
uniqNames msgfunc = uniq name (\x -> msgfunc (name x))

-- Find a cycle in a graph
grCycle :: Graph gr => gr a b -> Maybe [LNode a]
grCycle g = case mapMaybe nodeCycle (nodes g) of
                 []  -> Nothing
                 c:_ -> Just c
  where
    nodeCycle n = listToMaybe $ map (\s -> map (\i -> (i, fromJust $ lab g i)) (n:(esp s n g))) $ 
                                filter (\s -> elem n (reachable s g)) $ suc g n

--Logarithm to base 2. Equivalent to floor(log2(x))
log2 :: Integer -> Int
log2 0 = 0
log2 1 = 0
log2 n 
    | n>1 = 1 + log2 (n `div` 2)
    | otherwise = error "log2: negative argument"

-- The number of bits required to encode range [0..i]
bitWidth :: (Integral a) => a -> Int
bitWidth i = 1 + log2 (fromIntegral i)

mapIdx :: (a -> Int -> b) -> [a] -> [b]
mapIdx f xs = map (uncurry f) $ zip xs [0..]

mapIdxM :: (Monad m) => (a -> Int -> m b) -> [a] -> m [b]
mapIdxM f xs = mapM (uncurry f) $ zip xs [0..]

mapIdxM_ :: (Monad m) => (a -> Int -> m ()) -> [a] -> m ()
mapIdxM_ f xs = mapM_ (uncurry f) $ zip xs [0..]

foldIdx :: (a -> b -> Int -> a) -> a -> [b] -> a
foldIdx f acc xs = foldl' (\acc' (x,idx) -> f acc' x idx) acc $ zip xs [0..]

foldIdxM :: (Monad m) => (a -> b -> Int -> m a) -> a -> [b] -> m a
foldIdxM f acc xs = foldM (\acc' (x,idx) -> f acc' x idx) acc $ zip xs [0..]

-- parse binary number
readBin :: String -> Integer
readBin s = foldl' (\acc c -> (acc `shiftL` 1) +
                              case c of
                                   '0' -> 0
                                   '1' -> 1
                                   _   -> error $ "readBin" ++ s) 0 s

-- Determine the most significant set bit of a non-negative number 
-- (returns 0 if not bits are set)
msb :: (Bits b, Num b) => b -> Int
msb 0 = 0
msb 1 = 0
msb n = 1 + (msb $ n `shiftR` 1)

bitSlice :: (Bits a, Num a) => a -> Int -> Int -> a
bitSlice v h l = (v `shiftR` l) .&. (2^(h-l+1) - 1)
