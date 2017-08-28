{-
Copyrights (c) 2017. VMware, Inc. All right reserved. 

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

{-# LANGUAGE ImplicitParams, RecordWildCards, OverloadedStrings #-}

module IR.Compile2IR ( compileSwitch
                     , compilePort
                     , (.+)
                     , val2Record) where

import Data.List
import Data.Maybe
import Control.Monad.State
import Text.PrettyPrint
import qualified Data.Map as M
import qualified Data.Graph.Inductive as G 
--import Debug.Trace

import Util 
import PP
import Pos
import Syntax
import NS
import Relation
import Expr
import Name
import Type
import Validate
import Role
import qualified IR.IR       as I
import qualified IR.Optimize as I

type CompileState a = State I.Pipeline a
type VMap = M.Map String String

addVar :: I.VarName -> I.Type -> CompileState ()
addVar n t = modify $ \(I.Pipeline vs cfg nd') -> I.Pipeline (M.insert n t vs) cfg nd'

allocNode ::  CompileState I.NodeId
allocNode = do
    I.Pipeline vs cfg nd <- get
    let nid = if' (G.order cfg == 0) 0 ((snd $ G.nodeRange cfg) + 1)
    put $ I.Pipeline vs (G.insNode (nid, I.Par []) cfg) nd
    return nid

setEntryNode :: I.NodeId -> CompileState ()
setEntryNode nd = modify $ \(I.Pipeline vs cfg _) -> I.Pipeline vs cfg nd

updateNode :: I.NodeId -> I.Node -> [I.NodeId] -> CompileState ()
updateNode nid n suc = modify $ \(I.Pipeline vs cfg end) -> let (to, _, _, from) = G.context cfg nid
                                                                cfg' = (to, nid, n, from) G.& (G.delNode nid cfg)
                                                                cfg'' = foldl' (\_cfg s -> G.insEdge (nid, s, I.Edge) _cfg) cfg' suc
                                                            in I.Pipeline vs cfg'' end

compileSwitch :: Refine -> Relation -> [(String, I.Pipeline)]
compileSwitch r rel = map (\port -> (name port, compilePort r port)) ports
    where
    ports = filter (\role -> roleIsInPort r (name role) && portRoleSwitch r role == name rel) 
                   $ refineRoles r

compilePort :: Refine -> Role -> I.Pipeline
compilePort r role = let ?r = r in execState (compilePort' role) (I.Pipeline M.empty G.empty 0)

compilePort' :: (?r::Refine) => Role -> CompileState ()
compilePort' role@Role{..} = do 
    entrynd <- allocNode
    setEntryNode entrynd
    let inlined = exprInline ?r (CtxRole role) roleBody
    let e = {-trace ("inlined spec:\n\n" ++ show inlined) $-} evalState (expr2Statement ?r (CtxRole role) inlined) 0
    case exprValidate ?r (CtxRole role) e of
         Left er  -> error $ "Compile2IR.compilePort': failed to validate transformed expression: " ++ er
         Right _  -> return ()

    let rel = getRelation ?r roleTable
    plvars <- gets (M.keys . I.plVars)
    (vars, asns) <- declAsnVar M.empty roleKey (relRecordType rel) entrynd $ relCols rel
    pl <- get
    let c = eBinOp Eq (eField (eVar roleKey) "portnum") (eField ePacket "portnum")
    let (cdeps, cpl) = exprDeps vars (CtxRole role) rel roleKey c pl
        cdeps' = cdeps `intersect` plvars
    (entryndb, _) <- {-trace ("port statement:\n\n" ++ show e) $-} compileExpr vars (CtxRole role) Nothing e
    updateNode entrynd (I.Lookup (name rel) cdeps' cpl (I.BB asns $ I.Goto entryndb) (I.BB [] I.Drop)) [entryndb]
    -- TODO: optimize 

compileExpr :: (?r::Refine) => VMap -> ECtx -> Maybe I.NodeId -> Expr -> CompileState (I.NodeId, VMap)
compileExpr vars ctx exitnd e = do
    entrynd <- allocNode
    vars' <- compileExprAt vars ctx entrynd exitnd e
    return (entrynd, vars')

compileExprAt :: (?r::Refine) => VMap -> ECtx -> I.NodeId -> Maybe I.NodeId -> Expr -> CompileState VMap
compileExprAt vars ctx entrynd exitnd (E e@(ESeq _ e1 e2)) = do
    entrynd2 <- allocNode
    vars' <- compileExprAt vars (CtxSeq1 e ctx) entrynd (Just entrynd2) e1
    _ <- compileExprAt vars' (CtxSeq2 e ctx) entrynd2 exitnd e2
    return vars

compileExprAt vars ctx entrynd Nothing (E e@(EPar _ e1 e2)) = do
    (entrynd1, _) <- compileExpr vars (CtxPar1 e ctx) Nothing e1
    (entrynd2, _) <- compileExpr vars (CtxPar2 e ctx) Nothing e2
    updateNode entrynd (I.Par [I.BB [] $ I.Goto entrynd1, I.BB [] $ I.Goto entrynd2]) [entrynd1, entrynd2]
    return vars

compileExprAt vars ctx entrynd exitnd (E e@(EITE _ c t me)) = do
    let c' = mkScalarExpr vars (CtxITEIf e ctx) c
    (entryndt, _) <- compileExpr vars (CtxITEThen e ctx) exitnd t
    case me of
         Just el -> do 
                (entrynde, _) <- compileExpr vars (CtxITEElse e ctx) exitnd el
                updateNode entrynd (I.Cond [(c', I.BB [] $ I.Goto entryndt), (I.EBool True, I.BB [] $ I.Goto entrynde)]) [entryndt, entrynde]
         Nothing -> updateNode entrynd (I.Cond [(c', I.BB [] $ I.Goto entryndt), (I.EBool True, I.BB [] $ maybe I.Drop I.Goto exitnd)]) $ entryndt:(maybeToList exitnd)
    return vars

compileExprAt vars _   entrynd _      (E (EDrop _)) = do
    updateNode entrynd (I.Par [I.BB [] I.Drop]) []
    return vars

compileExprAt vars _   entrynd exitnd (E (ESet _ (E EPHolder{}) _)) = ignore vars entrynd exitnd

compileExprAt vars ctx entrynd exitnd (E e@(ESet _ e1 e2)) = do
    let e1' = mkExpr vars (CtxSetL e ctx) e1
        e2' = mkExpr vars (CtxSetR e ctx) e2
    let asns = map (uncurry I.ASet) $ zip e1' e2'
    updateNode entrynd (I.Par [I.BB asns $ maybe I.Drop I.Goto exitnd]) $ maybeToList exitnd
    return vars

compileExprAt vars ctx entrynd Nothing (E e@(ESend _ (E el@(ELocation _ _ x)))) = do
    let port = mkScalarExpr vars (CtxLocation el (CtxSend e ctx)) $ eField x "portnum"
    updateNode entrynd (I.Par [I.BB [] $ I.Send port]) []
    return vars

compileExprAt vars ctx entrynd Nothing (E e@(EFork _ v t c b)) = do
    -- Transform the fork statement to drop packets that do not match
    -- the fork condition right after fork.  This is necessary, since
    -- our OpenFlow backend will fork a packet on every row of the table.
    -- We still keep the condition in the Fork node, so we can use it
    -- in optimizations.
    let b' = eSeq (eITE (eNot c) eDrop Nothing) b
    let rel = getRelation ?r t
        cols = relCols rel
    plvars <- gets (M.keys . I.plVars)
    (vars', asns) <- declAsnVar vars v (relRecordType rel) entrynd cols
    pl <- get
    let (cdeps, cpl) = exprDeps vars' (CtxForkCond e ctx) rel v c pl
        cdeps' = cdeps `intersect` plvars
    (entryndb, _) <- compileExpr vars' (CtxForkBody e ctx) Nothing b'
    updateNode entrynd (I.Fork t cdeps' cpl $ I.BB asns $ I.Goto entryndb) [entryndb]
    return vars

compileExprAt vars ctx entrynd exitnd (E e@(EWith _ v t c b md)) = do
    let rel = getRelation ?r t
        cols = relCols rel
    plvars <- gets (M.keys . I.plVars)
    (vars', asns) <- declAsnVar vars v (relRecordType rel) entrynd cols
    pl <- get
    let (cdeps, cpl) = exprDeps vars' (CtxWithCond e ctx) rel v c pl
        cdeps' = cdeps `intersect` plvars
    (entryndb, _) <- compileExpr vars' (CtxWithBody e ctx) exitnd b
    case md of
         Just d -> do
             (entryndd, _) <- compileExpr vars (CtxWithDef e ctx) exitnd d
             updateNode entrynd (I.Lookup t cdeps' cpl (I.BB asns $ I.Goto entryndb) (I.BB asns $ I.Goto entryndd)) [entryndb, entryndd]
         Nothing -> updateNode entrynd (I.Lookup t cdeps' cpl (I.BB asns $ I.Goto entryndb) (I.BB [] I.Drop)) [entryndb]
    return vars

compileExprAt vars _   entrynd exitnd (E (ETyped _ (E (EVarDecl _ v)) t)) = do
    (vars', _) <- declVar vars v t entrynd
    updateNode entrynd (I.Par [I.BB [] $ maybe I.Drop I.Goto exitnd]) $ maybeToList exitnd
    return vars'

compileExprAt vars ctx entrynd exitnd (E e@(EPut _ t v)) = do
    let v' = mkExpr vars (CtxPut e ctx) v
    updateNode entrynd (I.Par [I.BB [I.APut t v'] $ maybe I.Drop I.Goto exitnd]) $ maybeToList exitnd
    return vars

compileExprAt vars ctx entrynd exitnd (E e@(EDelete _ t c)) = do
    let c' = mkScalarExpr vars (CtxDelete e ctx) c
    updateNode entrynd (I.Par [I.BB [I.ADelete t c'] $ maybe I.Drop I.Goto exitnd]) $ maybeToList exitnd
    return vars
 
compileExprAt vars ctx entrynd exitnd (E e@(EMatch _ m cs)) = do
    let csext = cs ++ if (fst (last cs) == ePHolder) then [] else [(ePHolder, eDrop)]
    cs' <- mapIdxM (\(c, a) i -> do entrya_ <- allocNode
                                    vars' <- foldM (\_vars (v, t) -> do 
                                                     (vars', _) <- declVar _vars v t entrya_
                                                     return vars')
                                                   vars $ matchVars (CtxMatchPat e ctx i) c
                                    (entrya, _) <- compileExpr vars' (CtxMatchVal e ctx i) exitnd a
                                    let (c', asns) = mkMatchCond vars' (CtxMatchPat e ctx i) m c
                                    updateNode entrya_ (I.Par [I.BB asns $ I.Goto entrya]) [entrya]
                                    return (c', entrya_))
                   csext
    updateNode entrynd (I.Cond $ map (\(c,entry) -> (c, I.BB [] $ I.Goto entry)) cs') $ map snd cs'
    return vars

-- expressions without LHS can be ignored, as they should not have
-- side effects (after running them through expr2Statement)
compileExprAt vars _   entrynd exitnd (E ETuple{})   = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EVar{})     = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EPacket{})  = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EField{})   = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EBool{})    = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EBit{})     = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EStruct{})  = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E ESlice{})   = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EBinOp{})   = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EUnOp{})    = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E ETyped{})   = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EPHolder{}) = ignore vars entrynd exitnd
compileExprAt vars _   entrynd exitnd (E EAnon{})    = ignore vars entrynd exitnd
compileExprAt _    _   _       _      e              = error $ "Compile2IR: compileExprAt " ++ show e

-- Compile boolean expression and determine its dependencies without changing compilation state
exprDeps :: (?r::Refine) => VMap -> ECtx -> Relation -> String -> Expr -> I.Pipeline -> ([I.VarName], I.Pipeline)
exprDeps vars ctx rel relvar e pl = (deps, pl''')
    where (entry, pl') = runState (exprDeps' vars ctx e) pl
          -- isolate subgraph that computes e only
          cfg' = G.nfilter (\nd -> elem nd $ G.dfs [entry] (I.plCFG pl')) $ I.plCFG pl'
          -- optimize to eliminate unused variables
          pl'' = I.optimize (-1000) $ pl{I.plEntryNode = entry, I.plCFG = cfg'}
          -- substitute variable names with column names
          cols = relCols rel
          relvs = map fst $ var2Scalars relvar (relRecordType rel)
          pl''' = foldl' (\pl_ (v,c) -> I.plSubstVar v c pl_) pl'' (zip relvs cols)
          -- all variables occurring in the expression
          evars = nub $ concatMap nodeVars $ map snd $ G.labNodes $ I.plCFG pl'''
          -- variables 
          deps = evars `intersect` (M.keys $ I.plVars pl)
          -- new variables declared in the expression
          --evars' = I.plVars pl'' M.\\ I.plVars pl


exprDeps' :: (?r::Refine) => VMap -> ECtx -> Expr -> CompileState I.NodeId
exprDeps' vars ctx e = do
    -- make sure I.optimize keep variables that effect the result of e
    -- by inserting a fake drop depending on the value of e. 
    -- Note: IR2OF.hs relies on this behavior
    let e' = exprModifyResult (\e_ -> eITE e_ eDrop Nothing) e
    entrynd <- allocNode
    exitnd <- allocNode
    _ <- compileExprAt vars ctx entrynd (Just exitnd) e'
    return entrynd

nodeVars :: I.Node -> [I.VarName]
nodeVars (I.Cond cs)             = nub $ concatMap (\(e,b) -> I.exprVars e ++ I.bbVars b) cs
nodeVars (I.Par bs)              = nub $ concatMap I.bbVars bs
nodeVars n                       = error $ "Compile2IR.nodeVars " ++ show n

ignore :: VMap -> I.NodeId -> Maybe I.NodeId -> CompileState VMap
ignore vars entrynd exitnd = do
    updateNode entrynd (I.Par [I.BB [] $ maybe I.Drop I.Goto exitnd]) $ maybeToList exitnd
    return vars

declVar :: (?r::Refine) => VMap -> String -> Type -> I.NodeId -> CompileState (VMap, [(I.VarName, I.Type)])
declVar vars vname vtype nd = do
    let vname' = vnameAt vname nd
    let vs = var2Scalars vname' vtype
    mapM_ (\(n, t) -> addVar n t) vs
    return (M.insert vname vname' vars, vs)

vnameAt :: String -> I.NodeId -> I.VarName
vnameAt v nd = v ++ "@" ++ show nd

declAsnVar :: (?r::Refine) => VMap -> String -> Type -> I.NodeId -> [I.Expr] -> CompileState (VMap, [I.Action])
declAsnVar vars vname vtype nd vals = do
    (vars', vs) <- declVar vars vname vtype nd
    let asns = map (uncurry I.ASet) $ zip (map (uncurry I.EVar) vs) vals
    return (vars', asns)

mkMatchCond :: (?r::Refine) => VMap -> ECtx -> Expr -> Expr -> (I.Expr, [I.Action])
mkMatchCond vars ctx m pat = (I.conj conds, acts)
    where
    (conds, acts) = foldl' (\(cs, as) (e1, me2) -> 
                               case me2 of
                                    Nothing          -> (cs, as)
                                    Just e2@I.EVar{} -> (cs, I.ASet e2 e1: as)
                                    Just e2          -> (I.EBinOp Eq e1 e2: cs, as)) ([], [])
                    $ zip (mkExpr vars ctx m) (expandPattern vars ctx pat)

matchVars :: (?r::Refine) => ECtx -> Expr -> [(String, Type)]
matchVars ctx e = map (\(v, ctx') -> (v, exprType ?r ctx' $ eVarDecl v)) $ exprVarDecls ctx e

expandPattern :: (?r::Refine) => VMap -> ECtx -> Expr -> [Maybe I.Expr]
expandPattern vars ctx e = exprTreeFlatten $ exprFoldCtx (expandPattern' vars) ctx e

expandPattern' :: (?r::Refine) => VMap -> ECtx -> ExprNode (ExprTree (Maybe I.Expr)) -> ExprTree (Maybe I.Expr)
expandPattern' vars ctx (EVarDecl _ v)   = fields "" (exprType ?r ctx $ eVarDecl v) (\t n -> Just $ I.EVar ((vars M.! v) .+ n) t)
expandPattern' _    ctx (EPHolder _)     = fields "" (exprType ?r ctx ePHolder) (\_ _ -> Nothing)
expandPattern' _    _   (EStruct _ c fs) = ETNode $ tag ++ fls
    where TStruct _ cs = fromJust $ tdefType $ consType ?r c
          Constructor{..} = getConstructor ?r c
          tag = if' (needsTag cs) [("_tag", ETLeaf $ Just $ I.EBit (tagWidth cs) (tagVal cs c))] []
          fls = map (\f -> let tree = case findIndex (== f) consArgs of
                                           Just i  -> fs !! i
                                           Nothing -> fields "" (typ f) (\_ _ -> Nothing)
                                      in (name f, tree)) $ structFields cs
expandPattern' _    _   (ETuple _ fs)    = ETNode $ mapIdx (\f i -> (show i, f)) fs
expandPattern' _    _   e                = error $ "Compile2IR.expandPattern' " ++ show e

-- function calls
-- version of expr2Statement that inlines function calls

mkScalarExpr :: (?r::Refine) => VMap -> ECtx -> Expr -> I.Expr
mkScalarExpr vars ctx e = e' where [e'] = mkExpr vars ctx e

relCols :: (?r::Refine) => Relation -> [I.Expr]
relCols rel = exprTreeFlatten $ fields "" (relRecordType rel) $ \t n -> I.ECol n t

var2Scalars :: (?r::Refine) => String -> Type -> [(I.VarName, I.Type)]
var2Scalars v t = exprTreeFlatten $ fields "" t $ \t' n -> (v .+ n, t')

data ExprTree a = ETNode [(String, ExprTree a)] 
                | ETLeaf a

instance PP a => PP (ExprTree a) where
    pp (ETLeaf x)  = pp x
    pp (ETNode bs) = vcat $ map (\(n, t) -> pp n <> "-" <> pp t) bs

instance PP a => Show (ExprTree a) where
    show = render . pp

mkExpr :: (?r::Refine) => VMap -> ECtx -> Expr -> [I.Expr]
mkExpr vars ctx e = {-trace ("mkExpr " ++ show e ++ " in\n" ++ show ctx) $ -} exprTreeFlatten $ exprFoldCtx (mkExpr' vars) ctx e

mkExpr' :: (?r::Refine) => VMap -> ECtx -> ExprNode (ExprTree I.Expr) -> ExprTree I.Expr
mkExpr' vars ctx (EVar _ v)                          = {-trace ("\n\n\n\n***************EVar " ++ show v ++ " in\n" ++ show ctx ++ "\nvars: " ++ show vars) $-} fields "" (typ $ getVar ?r ctx v) (\t n -> I.EVar ((vars M.! v) .+ n) t)
mkExpr' _    _   (EPacket _)                         = fields "" (fromJust $ tdefType $ getType ?r packetTypeName) (flip I.EPktField)
mkExpr' _    _   (EField _ (ETNode fs) f)            = fromJust $ lookup f fs
mkExpr' _    _   (EBool _ b)                         = ETLeaf $ I.EBool b
mkExpr' _    _   (EBit _ w v)                        = ETLeaf $ I.EBit w v
mkExpr' _    ctx (EInt _ v)                        = case typ' ?r $ exprType ?r ctx (eInt v) of    
                                                          TBit _ w -> ETLeaf $ I.EBit w v
                                                          _        -> error $ "Compile2IR.mkExpr' " ++ show v ++ " not a bitvector type"
mkExpr' _    _   (EStruct _ c fs)                    = ETNode $ tag ++ fls
    where TStruct _ cs = fromJust $ tdefType $ consType ?r c
          Constructor{..} = getConstructor ?r c
          tag = if' (needsTag cs) [("_tag", ETLeaf $ I.EBit (tagWidth cs) (tagVal cs c))] []
          fls = map (\f -> let tree = case findIndex (== f) consArgs of
                                           Just i  -> fs !! i
                                           Nothing -> defaultETree $ typ f
                                      in (name f, tree)) $ structFields cs
mkExpr' _   _   (ETuple _ fs)                       = ETNode $ mapIdx (\f i -> (show i, f)) fs 
mkExpr' _   _   (ESlice _ (ETLeaf e) h l)           = ETLeaf $ I.ESlice e h l
mkExpr' _   _   (EBinOp _ op (ETLeaf e1) (ETLeaf e2)) = ETLeaf $ I.EBinOp op e1 e2
mkExpr' _   _   (EBinOp _ Eq t1 t2)                 = ETLeaf $ I.conj
                                                      $ map (\(e1, e2) -> I.EBinOp Eq e1 e2)
                                                      $ zip (exprTreeFlatten t1) (exprTreeFlatten t2)
mkExpr' _   _   (EBinOp _ Neq t1 t2)                = ETLeaf $ I.disj
                                                      $ map (\(e1, e2) -> I.EBinOp Neq e1 e2)
                                                      $ zip (exprTreeFlatten t1) (exprTreeFlatten t2)
mkExpr' _   _   (EUnOp _ op (ETLeaf e))             = ETLeaf $ I.EUnOp op e
mkExpr' _   _   (ETyped _ e _)                      = e
mkExpr' _   ctx EAnon{}                             = fields "" (exprType ?r ctx eAnon) $ flip I.ECol
mkExpr' _   _   e                                   = error $ "Compile2IR.mkExpr' " ++ show e

(.+) :: String -> String -> String
(.+) "" s  = s
(.+) s ""  = s
(.+) s1 s2 = s1 ++ "." ++ s2


fields :: (?r::Refine) => String -> Type -> (I.Type -> String -> a) -> ExprTree a
fields pref t f = 
    case typ' ?r t of
         TBool _      -> ETLeaf $ f I.TBool pref
         TBit _ w     -> ETLeaf $ f (I.TBit w) pref
         TStruct _ cs -> ETNode $ (if' (needsTag cs) [("_tag", fields (pref .+ "_tag") (tagType cs) f)] []) ++ (map (\fl -> (name fl, fields (pref .+ name fl) (typ fl) f)) $ structFields cs)
         TTuple _ as  -> ETNode $ mapIdx (\t' i -> (show i, fields (pref .+ show i) t' f)) as
         t'           -> error $ "Compile2IR.fields " ++ show t'


exprTreeFlatten :: ExprTree a -> [a]
exprTreeFlatten (ETLeaf x) = [x]
exprTreeFlatten (ETNode ts) = concatMap (exprTreeFlatten . snd) ts

defaultETree :: (?r::Refine) => Type -> ExprTree I.Expr
defaultETree t =
    case typ' ?r t of
         TBool _      -> ETLeaf $ I.EBool False
         TBit _ w     -> ETLeaf $ I.EBit w 0
         TStruct _ cs -> ETNode $ (if' (needsTag cs) [("_tag", defaultETree $ tagType cs)] []) ++ (map (\fl -> (name fl, defaultETree (typ fl))) $ structFields cs)
         TTuple _ as  -> ETNode $ mapIdx (\t' i -> (show i, defaultETree t')) as
         t'           -> error $ "Compile2IR.defaultETree " ++ show t'

needsTag :: [Constructor] -> Bool
needsTag cs = length cs > 1

tagWidth :: [Constructor] -> Int
tagWidth cs = bitWidth $ length cs - 1

tagType :: [Constructor] -> Type
tagType cs = TBit nopos $ tagWidth cs

tagVal :: [Constructor] -> String -> Integer
tagVal cs c = fromIntegral $ fromJust $ findIndex ((== c) . name) cs

val2Record :: (?r::Refine) => String -> Expr -> I.Record
val2Record rname e@(E (EStruct{})) = M.fromList $ zip names vals
    where
    vals = mkExpr M.empty CtxRefine e
    rel = getRelation ?r rname
    names = exprTreeFlatten $ fields "" (relRecordType rel) (\_ n -> n)
val2Record _ e = error $ "Compile2IR.val2Record " ++ show e

