{-# LANGUAGE ImplicitParams #-}

module MiniNet.MiniNet (generateMininetTopology) where

import Text.JSON
import Data.Maybe
import Control.Monad.State
import Debug.Trace

import Topology
import Util
import Syntax
import Eval
import NS
import Name

hstep = 100
vstep = 100

type Switches = [JSValue]
type Hosts    = [JSValue]
type Links    = [JSValue]
type NodeMap  = [(InstanceDescr, String)]

generateMininetTopology :: Refine -> Topology -> (String, NodeMap)
generateMininetTopology r topology = (encode $ toJSObject attrs, nmap)
    where -- max number of nodes in a layer
          width = maximum $ map (length . (uncurry instMapFlatten)) topology
          -- render nodes
          (sws, hs, nmap) = execState (mapIdxM (renderNodes r width) topology) ([],[],[])
          -- render links
          links = let ?r = r in
                  let ?t = topology in
                  concatMap (\(n, imap) -> concatMap (\(descr, plinks) -> renderLinks nmap descr plinks) $ instMapFlatten n imap) topology
          attrs = [ ("controllers", JSArray [])
                  , ("hosts"      , JSArray hs)
                  , ("switches"   , JSArray sws)
                  , ("links"      , JSArray links)
                  , ("version"    , JSRational False 2)
                  ]
          
renderNodes :: Refine -> Int -> (Node, InstanceMap) -> Int -> State (Switches, Hosts, NodeMap) ()
renderNodes r w (n, imap) voffset = do 
    let nodes = instMapFlatten n imap
        offset = (w - length nodes) `div` 2
        nodeoff = zip nodes [offset..]
    mapM_ (renderNode voffset n) nodeoff

renderNode :: Int -> Node -> ((InstanceDescr, PortLinks), Int) -> State (Switches, Hosts, NodeMap) ()
renderNode voffset node ((descr, links), hoffset) = do
    (sws, hs, nmap) <- get
    let (letter, number) = if' (nodeType node == NodeSwitch) ("s", length sws) ("h", length hs)
        ndname = letter ++ show number
        opts = [ ("controllers", JSArray [])
               , ("hostname"   , JSString $ toJSString ndname) 
               , ("nodeNum"    , JSRational False $ fromIntegral number)
               , ("switchType" , JSString $ toJSString "bmv2")]
        attrs = [ ("number", JSString $ toJSString $ show number)
                , ("opts"  , JSObject $ toJSObject opts)
                , ("x"     , JSString $ toJSString $ show $ (hoffset + 1) * hstep)
                , ("y"     , JSString $ toJSString $ show $ (voffset + 1) * vstep)]
        n = JSObject $ toJSObject attrs 
        nmap' = (descr, ndname):nmap
    put $ if' (nodeType node == NodeSwitch) ((n:sws), hs, nmap') (sws, (n:hs), nmap')

renderLinks :: (?t::Topology,?r::Refine) => NodeMap -> InstanceDescr -> PortLinks -> Links
renderLinks nmap node plinks = 
    concatMap (\((_,o), (base,_), links) -> mapMaybe (renderLink nmap node base) links) plinks

renderLink :: (?t::Topology,?r::Refine) => NodeMap -> InstanceDescr -> Int -> (Int, Maybe PortInstDescr) -> Maybe JSValue
renderLink nmap srcnode srcprtbase (srcportnum, Just dstportinst@(PortInstDescr dstpname dstkeys)) = Just $ JSObject $ toJSObject attrs
    where dstnode = nodeFromPort ?r ?t dstportinst
          dstpnum = phyPortNum ?t dstnode dstpname (fromInteger $ exprIVal $ last dstkeys)
          attrs = [ ("src"     , JSString $ toJSString $ fromJust $ lookup srcnode nmap)
                  , ("srcport" , JSRational False $ fromIntegral $ srcportnum + srcprtbase)
                  , ("dest"    , JSString $ toJSString $ fromJust $ lookup dstnode nmap)
                  , ("destport", JSRational False $ fromIntegral dstpnum)
                  , ("opts"    , JSObject $ toJSObject ([]::[(String, JSValue)]))]
renderLink _ _ _ _ = Nothing