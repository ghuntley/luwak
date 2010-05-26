-module(luwak_tree).

-export([update/4, get/2, block_at/3, visualize_tree/2, get_range/6]).

-include_lib("luwak/include/luwak.hrl").

%%=======================================
%% Public API
%%=======================================
update(Riak, File, StartingPos, Blocks) ->
  Order = luwak_file:get_property(File, tree_order),
  BlockSize = luwak_file:get_property(File, block_size),
  if
    StartingPos rem BlockSize =/= 0 -> throw({error, "StartingPos must be a multiple of blocksize"});
    true -> ok
  end,
  case luwak_file:get_property(File, root) of
    %% there is no root, therefore we create one
    undefined -> 
      {ok, RootObj} = create_tree(Riak, Order, Blocks),
      RootName = riak_object:key(RootObj),
      luwak_file:update_root(Riak, File, RootName);
    RootName ->
      {ok, Root} = get(Riak, RootName),
      error_logger:info_msg("blocks~n"),
      WriteLength = luwak_tree_utils:blocklist_length(Blocks),
      error_logger:info_msg("children~n"),
      RootLength = luwak_tree_utils:blocklist_length(Root#n.children),
      {ok, NewRoot} = subtree_update(Riak, File, Order, StartingPos, 0, 
        Root, Blocks),
      NewRootName = riak_object:key(NewRoot),
      luwak_file:update_root(Riak, File, NewRootName)
  end.

get_range(_, _, _, _, _, 0) ->
  [];
% get_range(_, _, _, TreeStart, Start, _) when Start < TreeStart ->
%   error_logger:info_msg("C get_range(_, _, _, ~p, ~p, _)~n", [TreeStart, Start]),
%   %% what are you even doing here
%   [];
get_range(Riak, Parent = #n{children=[]}, BlockSize, TreeStart, Start, End) ->
  error_logger:info_msg("D get_range(_, _, _, _, _, _)~n"),
  [];
%% children are individual blocks
%% we can do this because trees are guaranteed to be full
get_range(Riak, Parent = #n{children=[{_,BlockSize}|_]=Children}, BlockSize, TreeStart, Start, End) ->
  error_logger:info_msg("A get_range(Riak, ~p, ~p, ~p, ~p, ~p)~n", [Parent, BlockSize, TreeStart, Start, End]),
  read_split(Children, TreeStart, Start, End);
get_range(Riak, Parent = #n{children=Children}, BlockSize, TreeStart, Start, End) ->
  error_logger:info_msg("B get_range(Riak, ~p, ~p, ~p, ~p, ~p)~n", [Parent, BlockSize, TreeStart, Start, End]),
  Nodes = read_split(Children, TreeStart, Start, End),
  luwak_tree_utils:foldrflatmap(fun({Name,NodeLength}, AccLength) ->
      error_logger:info_msg("foldrflatmap({~p,~p}, ~p)~n", [Name, NodeLength, AccLength]),
      {ok, Node} = get(Riak, Name),
      Blocks = get_range(Riak, Node, BlockSize, AccLength, Start, End),
      {Blocks, AccLength+NodeLength}
    end, Nodes, TreeStart).
  
read_split(Children, TreeStart, Start, End) when Start < 0 ->
  read_split(Children, TreeStart, 0, End);
read_split(Children, TreeStart, Start, End) ->
  error_logger:info_msg("read_split(~p, ~p, ~p, ~p)~n", [Children, TreeStart, Start, End]),
  InsidePos = Start - TreeStart,
  InsideEnd = End - TreeStart,
  {Head,Tail} = luwak_tree_utils:split_at_length(Children, InsidePos),
  {Middle,_} = luwak_tree_utils:split_at_length_left_bias(Tail, InsideEnd),
  error_logger:info_msg("middle ~p~n", [Middle]),
  Middle.

get(Riak, Name) when is_binary(Name) ->
  {ok, Obj} = Riak:get(?N_BUCKET, Name, 2),
  {ok, riak_object:get_value(Obj)}.
  
visualize_tree(Riak, RootName) ->
  {ok, Node} = get(Riak, RootName),
    [<<"digraph Luwak_Tree {\n">>,
    <<"# page = \"8.2677165,11.692913\" ;\n">>,
    <<"ratio = \"auto\" ;\n">>,
    <<"mincross = 2.0 ;\n">>,
    <<"label = \"Luwak Tree\" ;\n">>,
    visualize_tree(Riak, RootName, Node),
    <<"}">>].
  
visualize_tree(Riak, RootName = <<Prefix:8/binary, _/binary>>, #n{children=Children}) ->
  io_lib:format("\"~s\" [shape=circle,label=\"~s\",regular=1,style=filled,fillcolor=white ] ;~n", [RootName,Prefix]) ++
  lists:map(fun({ChildName,_}) ->
      {ok, Child} = get(Riak, ChildName),
      visualize_tree(Riak, ChildName, Child)
    end, Children) ++
  lists:map(fun({ChildName,Length}) ->
      io_lib:format("\"~s\" -> \"~s\" [dir=none,weight=1,label=\"~p\"] ;~n", [RootName,ChildName,Length])
    end, Children);
visualize_tree(Riak, DataName = <<Prefix:8/binary, _/binary>>, DataNode) ->
  Data = luwak_block:data(DataNode),
  io_lib:format("\"~s\" [shape=record,label=\"~s | ~s\",regular=1,style=filled,fillcolor=gray ] ;~n", [DataName,Prefix,Data]).

create_tree(Riak, Order, Children) when is_list(Children) ->
  % error_logger:info_msg("create_tree(Riak, ~p, ~p)~n", [Order, Children]),
  if
    length(Children) > Order ->
      Written = list_into_nodes(Riak, Children, Order, 0),
      create_node(Riak, Written);
    true ->
      create_node(Riak, Children)
  end.

%% updating any node happens in up to 5 parts, depending on the coverage of the write list
subtree_update(Riak, File, Order, InsertPos, TreePos, Parent = #n{}, Blocks) ->
  % error_logger:info_msg("subtree_update(Riak, File, ~p, ~p, ~p, ~p, ~p)~n", [Order, InsertPos, TreePos, Parent, truncate(Blocks)]),
  {NodeSplit, BlockSplit} = luwak_tree_utils:five_way_split(TreePos, Parent#n.children, InsertPos, Blocks),
  % error_logger:info_msg("NodeSplit ~p BlockSplit ~p~n", [NodeSplit, BlockSplit]),
  MidHeadStart = luwak_tree_utils:blocklist_length(NodeSplit#split.head) + TreePos,
  % error_logger:info_msg("midhead~n"),
  MidHeadReplacement = lists:map(fun({Name,Length}) ->
      {ok, ChildNode} = get(Riak, Name),
      {ok, ReplacementChild} = subtree_update(Riak, File, Order, 
        InsertPos, MidHeadStart, 
        ChildNode, BlockSplit#split.midhead),
      V = riak_object:get_value(ReplacementChild),
      {riak_object:key(ReplacementChild), luwak_tree_utils:blocklist_length(V#n.children)}
    end, NodeSplit#split.midhead),
  MiddleInsertStart = luwak_tree_utils:blocklist_length(BlockSplit#split.midhead) + MidHeadStart,
  % error_logger:info_msg("middle~n"),
  MiddleReplacement = list_into_nodes(Riak, BlockSplit#split.middle, Order, MiddleInsertStart),
  MidTailStart = luwak_tree_utils:blocklist_length(BlockSplit#split.middle) + MiddleInsertStart,
  % error_logger:info_msg("midtail~n"),
  MidTailReplacement = lists:map(fun({Name,Length}) ->
      {ok, ChildNode} = get(Riak, Name),
      {ok, ReplacementChild} = subtree_update(Riak, File, Order,
        MidTailStart, MidTailStart,
        ChildNode, BlockSplit#split.midtail),
      V = riak_object:get_value(ReplacementChild),
      {riak_object:key(ReplacementChild), luwak_tree_utils:blocklist_length(V#n.children)}
    end, NodeSplit#split.midtail),
  % error_logger:info_msg("end~n"),
  create_tree(Riak, Order, NodeSplit#split.head ++ 
    MidHeadReplacement ++ 
    MiddleReplacement ++ 
    MidTailReplacement ++
    NodeSplit#split.tail).
  
list_into_nodes(Riak, Children, Order, StartingPos) ->
  % error_logger:info_msg("list_into_nodes(Riak, ~p, ~p, ~p)~n", [Children, Order, StartingPos]),
  map_sublist(fun(Sublist) ->
      Length = luwak_tree_utils:blocklist_length(Sublist),
      {ok, Obj} = create_node(Riak, Sublist),
      {riak_object:key(Obj), Length}
    end, Order, Children).
  

%% @spec block_at(Riak::riak(), File::luwak_file(), Pos::int()) ->
%%          {ok, BlockObj} | {error, Reason}
block_at(Riak, File, Pos) ->
  BlockSize = luwak_file:get_property(File, block_size),
  Length = luwak_file:get_property(File, length),
  case luwak_file:get_property(File, root) of
    undefined -> {error, notfound};
    % RootName when Pos > Length -> eof;
    RootName ->
      block_at_retr(Riak, RootName, 0, Pos)
  end.

block_at_retr(Riak, NodeName, NodeOffset, Pos) ->
  case Riak:get(?N_BUCKET, NodeName, 2) of
    {ok, NodeObj} ->
      Type = luwak_file:get_property(NodeObj, type),
      Links = luwak_file:get_property(NodeObj, links),
      block_at_node(Riak, NodeObj, Type, Links, NodeOffset, Pos);
    Err -> Err
  end.
  
block_at_node(Riak, NodeObj, node, Links, NodeOffset, Pos) ->
  ChildName = which_child(Links, NodeOffset, Pos),
  block_at_retr(Riak, ChildName, NodeOffset, Pos);
block_at_node(Riak, NodeObj, block, _, NodeOffset, _) ->
  {ok, NodeObj}.
  
which_child([{ChildName,_}|[]], _, _) ->
  ChildName;
which_child([{ChildName,Length}|Tail], NodeOffset, Pos) when Pos > NodeOffset + Length ->
%  error_logger:info_msg("which_child(~p, ~p, ~p)~n", [[{ChildName,Length}|Tail], NodeOffset, Pos]),
  which_child(Tail, NodeOffset+Length, Pos);
which_child([{ChildName,Length}|Tail], NodeOffset, Pos) when Pos =< NodeOffset + Length ->
%  error_logger:info_msg("which_child(~p, ~p, ~p)~n", [[{ChildName,Length}|Tail], NodeOffset, Pos]),
  ChildName.

map_sublist(Fun, N, List) ->
  map_sublist_1(Fun, N, List, [], []).
  
map_sublist_1(_, _, [], [], Acc) ->
  lists:reverse(Acc);
map_sublist_1(_, N, [], Sublist, []) when length(Sublist) < N ->
  lists:reverse(Sublist);
map_sublist_1(Fun, N, [], Sublist, Acc) ->
  lists:reverse([Fun(lists:reverse(Sublist))|Acc]);
map_sublist_1(Fun, N, List, Sublist, Acc) when length(Sublist) >= N ->
  Result = Fun(lists:reverse(Sublist)),
  map_sublist_1(Fun, N, List, [], [Result|Acc]);
map_sublist_1(Fun, N, [E|List], Sublist, Acc) ->
  map_sublist_1(Fun, N, List, [E|Sublist], Acc).

create_node(Riak, Children) ->
  % error_logger:info_msg("create_node(Riak, ~p)~n", [Children]),
  N = #n{created=now(),children=Children},
  Name = skerl:hexhash(?HASH_LEN, term_to_binary(Children)),
  Obj = riak_object:new(?N_BUCKET, Name, N),
  {Riak:put(Obj, 2), Obj}.
    
floor(X) ->
  T = erlang:trunc(X),
  case (X - T) of
    Neg when Neg < 0 -> T - 1;
    Pos when Pos > 0 -> T;
    _ -> T
  end.

ceiling(X) ->
  T = erlang:trunc(X),
  case (X - T) of
    Neg when Neg < 0 -> T;
    Pos when Pos > 0 -> T + 1;
    _ -> T
  end.
  
truncate(List) when is_list(List) ->
  lists:map(fun({Data,Length}) -> {truncate(Data),Length} end, List);
truncate(Data = <<Prefix:8/binary, _/binary>>) -> Prefix.
