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
{-# LANGUAGE RecordWildCards #-}

module Refine( funcGraph
             , refineStructs
             , refineIsMulticast
             , refineIsDeterministic) where

import Data.List
import Data.Maybe
import qualified Data.Graph.Inductive as G

import Expr
import Syntax
import Name
import Role
import NS

funcGraph :: Refine -> G.Gr String ()
funcGraph Refine{..} = 
    let g0 = foldl' (\g (i,f) -> G.insNode (i,name f) g)
                    G.empty $ zip [0..] refineFuncs in
    foldl' (\g (i,f) -> case funcDef f of
                             Nothing -> g
                             Just e  -> foldl' (\g' f' -> G.insEdge (i, fromJust $ findIndex ((f'==) . name) $ refineFuncs, ()) g') g (exprFuncs e))
           g0 $ zip [0..] refineFuncs

refineStructs :: Refine -> [Type]
refineStructs r = concatMap (\t -> case t of 
                                        TypeDef _ _ (Just t'@(TStruct _ _)) -> [t']
                                        _                                   -> []) $ refineTypes r

refineIsMulticast :: Maybe Refine -> Refine -> String -> Bool
refineIsMulticast mra rc rlname = any (exprIsMulticast rc . roleBody . getRole rc) roles
    where new = maybe [] (\ra -> (map name (refineRoles rc) \\ map name (refineRoles ra))) mra
          roles = rlname : intersect new (roleSendsToRolesRec rc new rlname)
    
refineIsDeterministic :: Maybe Refine -> Refine -> String -> Bool
refineIsDeterministic mra rc rlname = any (exprIsDeterministic rc . roleBody . getRole rc) roles
    where new = maybe [] (\ra -> (map name (refineRoles rc) \\ map name (refineRoles ra))) mra
          roles = rlname : intersect new (roleSendsToRolesRec rc new rlname)
