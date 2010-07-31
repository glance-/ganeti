{-| Parsing data from text-files

This module holds the code for loading the cluster state from text
files, as produced by gnt-node and gnt-instance list.

-}

{-

Copyright (C) 2009, 2010 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Ganeti.HTools.Text
    (
      loadData
    , parseData
    , loadInst
    , loadNode
    , serializeInstances
    , serializeNode
    , serializeNodes
    , serializeCluster
    ) where

import Control.Monad
import Data.List

import Text.Printf (printf)

import Ganeti.HTools.Utils
import Ganeti.HTools.Loader
import Ganeti.HTools.Types
import qualified Ganeti.HTools.Container as Container
import qualified Ganeti.HTools.Node as Node
import qualified Ganeti.HTools.Instance as Instance

-- | Serialize a single node
serializeNode :: Node.Node -> String
serializeNode node =
    printf "%s|%.0f|%d|%d|%.0f|%d|%.0f|%c" (Node.name node)
               (Node.tMem node) (Node.nMem node) (Node.fMem node)
               (Node.tDsk node) (Node.fDsk node) (Node.tCpu node)
               (if Node.offline node then 'Y' else 'N')

-- | Generate node file data from node objects
serializeNodes :: Node.List -> String
serializeNodes = unlines . map serializeNode . Container.elems

-- | Serialize a single instance
serializeInstance :: Node.List -> Instance.Instance -> String
serializeInstance nl inst =
    let
        iname = Instance.name inst
        pnode = Container.nameOf nl (Instance.pNode inst)
        sidx = Instance.sNode inst
        snode = (if sidx == Node.noSecondary
                    then ""
                    else Container.nameOf nl sidx)
    in
      printf "%s|%d|%d|%d|%s|%s|%s|%s"
             iname (Instance.mem inst) (Instance.dsk inst)
             (Instance.vcpus inst) (Instance.runSt inst)
             pnode snode (intercalate "," (Instance.tags inst))

-- | Generate instance file data from instance objects
serializeInstances :: Node.List -> Instance.List -> String
serializeInstances nl =
    unlines . map (serializeInstance nl) . Container.elems

-- | Generate complete cluster data from node and instance lists
serializeCluster :: Node.List -> Instance.List -> String
serializeCluster nl il =
  let ndata = serializeNodes nl
      idata = serializeInstances nl il
  in ndata ++ ['\n'] ++ idata

-- | Load a node from a field list.
loadNode :: (Monad m) => [String] -> m (String, Node.Node)
loadNode [name, tm, nm, fm, td, fd, tc, fo] = do
  new_node <-
      if any (== "?") [tm,nm,fm,td,fd,tc] || fo == "Y" then
          return $ Node.create name 0 0 0 0 0 0 True
      else do
        vtm <- tryRead name tm
        vnm <- tryRead name nm
        vfm <- tryRead name fm
        vtd <- tryRead name td
        vfd <- tryRead name fd
        vtc <- tryRead name tc
        return $ Node.create name vtm vnm vfm vtd vfd vtc False
  return (name, new_node)
loadNode s = fail $ "Invalid/incomplete node data: '" ++ show s ++ "'"

-- | Load an instance from a field list.
loadInst :: (Monad m) =>
            [(String, Ndx)] -> [String] -> m (String, Instance.Instance)
loadInst ktn [name, mem, dsk, vcpus, status, pnode, snode, tags] = do
  pidx <- lookupNode ktn name pnode
  sidx <- (if null snode then return Node.noSecondary
           else lookupNode ktn name snode)
  vmem <- tryRead name mem
  vdsk <- tryRead name dsk
  vvcpus <- tryRead name vcpus
  when (sidx == pidx) $ fail $ "Instance " ++ name ++
           " has same primary and secondary node - " ++ pnode
  let vtags = sepSplit ',' tags
      newinst = Instance.create name vmem vdsk vvcpus status vtags pidx sidx
  return (name, newinst)
loadInst _ s = fail $ "Invalid/incomplete instance data: '" ++ show s ++ "'"

-- | Convert newline and delimiter-separated text.
--
-- This function converts a text in tabular format as generated by
-- @gnt-instance list@ and @gnt-node list@ to a list of objects using
-- a supplied conversion function.
loadTabular :: (Monad m, Element a) =>
               [String] -> ([String] -> m (String, a))
            -> m ([(String, Int)], [(Int, a)])
loadTabular lines_data convert_fn = do
  let rows = map (sepSplit '|') lines_data
  kerows <- mapM convert_fn rows
  return $ assignIndices kerows

-- | Load the cluser data from disk.
readData :: String -- ^ Path to the text file
         -> IO String
readData = readFile

-- | Builds the cluster data from text input.
parseData :: String -- ^ Text data
          -> Result (Node.AssocList, Instance.AssocList, [String])
parseData fdata = do
  let flines = lines fdata
      (nlines, ilines) = break null flines
  ifixed <- case ilines of
    [] -> Bad "Invalid format of the input file (no instance data)"
    _:xs -> Ok xs
  {- node file: name t_mem n_mem f_mem t_disk f_disk -}
  (ktn, nl) <- loadTabular nlines loadNode
  {- instance file: name mem disk status pnode snode -}
  (_, il) <- loadTabular ifixed (loadInst ktn)
  return (nl, il, [])

-- | Top level function for data loading
loadData :: String -- ^ Path to the text file
         -> IO (Result (Node.AssocList, Instance.AssocList, [String]))
loadData afile = readData afile >>= return . parseData
