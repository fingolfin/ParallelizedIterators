#
# ParallelizedIterators: Parallely evaluating recursive iterators
#
# Implementations
#

##
SetInfoLevel( InfoPtree, 1 );

##
SetInfoLevel( InfoRecursiveIterator, 1 );

##
InstallGlobalFunction( InsertPriorityQueue,
function(pq, prio, elem)
  if not IsBound( pq[prio] ) then
      pq[prio] := MigrateObj( [ elem ], pq );
  else
      Add( pq[prio], MigrateObj( elem, pq ) );
  fi;
end );

##
InstallGlobalFunction( GetPriorityQueue,
function(pq)
  local len, result;
  len := Length(pq);
  if len = 0 then
    return [fail, fail];
  fi;
  result := MigrateObj( [ len, Remove( pq[len] ) ], pq );
  if pq[len] = [ ] then
      Unbind(pq[len]);
  fi;
  return result;
end );

##
InstallGlobalFunction( NextLocallyUniformRecursiveIterator,
function(prio, iter)
  local next, leaves;
  
  if IsDoneIterator(iter) then
    return [];
  fi;
  
  next := NextIterator(iter);
  
  if IsIterator(next) then
    return [ prio+1, next ];
  fi;
  
  leaves := [ next ];
  
  while not IsDoneIterator(iter) do
    Add(leaves, NextIterator(iter));
  od;
  
  return [ leaves ];
end );

##
InstallGlobalFunction( EvaluateLocallyUniformRecursiveIterator,
function(state)
  local name, sem, ch, prio, iter, next, len, leaf, i;
  
  atomic state do
    state.current_number_of_workers := state.current_number_of_workers + 1;
    state.last_assigned_number := state.last_assigned_number + 1;
    name := Concatenation( "worker ", String( state.last_assigned_number ), " in thread #", String( ThreadID( CurrentThread( ) ) ) );
    sem := state.semaphore;
    ch := state.leaf_channel;
  od;
  
  SetRegionName( "", name );
  Info( InfoPtree, 2, "I am ", name, ". Welcome to my local thread." );
  
  while true do
    atomic state do
      state.(name) := MakeImmutable( "Waiting for semaphore" );
    od;
    Info( InfoPtree, 2, "Waiting for semaphore ..." );
    WaitSemaphore(sem);
    atomic state do
      state.(name) := MakeImmutable( "Waiting for semaphore ... DONE" );
    od;
    Info( InfoPtree, 2, "Done." );
    atomic state do
      Info( InfoPtree, 2, "currently ", state.number_of_current_jobs, " jobs awaiting free workers" );
      if state.canceled then
        iter := fail;
      else
        state.(name) := MakeImmutable( "GetPriorityQueue" );
        Info( InfoPtree, 2, "GetPriorityQueue ..." );
	iter := GetPriorityQueue(state.pq);
        state.(name) := MakeImmutable( "GetPriorityQueue ... DONE" );
        Info( InfoPtree, 2, "Done." );
	prio := iter[1];
	iter := iter[2];
        state.(name) := MakeImmutable( "Adopt ..." );
        Info( InfoPtree, 2, "Adopt ..." );
	AdoptObj(iter);
        state.(name) := MakeImmutable( "Adopt ... DONE" );
        Info( InfoPtree, 2, "Done." );
      fi;
    od;
    if iter = fail then
      atomic state do
        state.(name) := MakeImmutable( "Terminated!" );
      od;
      QUIT_GAP();
    fi;
    atomic state do
      state.(name) := MakeImmutable( Concatenation( "Computing at priority level ", String( prio ), " ..." ) );
    od;
    Info( InfoPtree, 2, "Computing ..." );
    next := NextLocallyUniformRecursiveIterator(prio, iter);
    Info( InfoPtree, 2, "Done." );
    atomic state do
      state.(name) := MakeImmutable( Concatenation( "Computing at priority level ", String( prio ), " ... DONE" ) );
    od;
    len := Length(next);
    atomic state do
      
      state.WallTime := state.WallTime_func();
      state.CPUTimes := state.CPUTimes_func();
      
      if len = 0 then # next = [ ], the iterateor is done without producing leaves
        
        state.number_of_current_jobs := state.number_of_current_jobs - 1;
        
      elif len = 1 then # next = [ [ leaves ] ], the iterator is done producing leaves
        
        ## write all produced leaves to the channel
        state.(name) := MakeImmutable( Concatenation( "Sending ", String( Length(next[1]) ), " leaves to channel ..." ) );
        Info( InfoPtree, 2, "Sending ", Length(next[1]), " leaves to channel ..." );
        for leaf in next[1] do
          SendChannel(ch, [ leaf, state.WallTime.total, state.CPUTimes.total ] );
        od;
        state.(name) := MakeImmutable( Concatenation( "Sending ", String( Length(next[1]) ), " leaves to channel ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
        state.number_of_leaves := state.number_of_leaves + Length(next[1]);
        state.number_of_current_jobs := state.number_of_current_jobs - 1;
        
      elif len = 2 then # next = [ prio, iter ] -> next task step
        
        ## insert next iterator into priority queue
        state.(name) := MakeImmutable( Concatenation( "insert next iterator of level ", String( next[1] ), " in priority queue ..." ) );
        Info( InfoPtree, 2, "insert next iterator of level ", next[1], " in priority queue ..." );
        InsertPriorityQueue(state.pq, next[1], next[2]);
        SignalSemaphore(sem);
        state.(name) := MakeImmutable( Concatenation( "insert next iterator of level ", String( next[1] ), " in priority queue ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
        ## return iterator to priority queue
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ..." ) );
        Info( InfoPtree, 2, "return iterator of level ", prio, " to priority queue ..." );
        InsertPriorityQueue(state.pq, prio, iter);
        SignalSemaphore(sem);
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
	state.number_of_current_jobs := state.number_of_current_jobs + 1;
        
      fi;
      
      ## the first worker who figures out that there are no jobs left
      ## (this implies that no other worker is busy) should send
      ## fail to the channel and help all workers finish by
      ## increasing the work semaphore `number_of_current_jobs' times.
      if state.number_of_current_jobs = 0 then
        SendChannel(ch, fail);
        SendChannel(ch, [ state.StartTimeStamp, state.WallTime.total, state.CPUTimes.total ]);
        for i in [ 1 .. state.current_number_of_workers ] do
	  SignalSemaphore(sem);
	od;
      fi;
    od;
  od;
end );

##
InstallGlobalFunction( NextRecursiveIterator,
function(prio, iter)
  local next;
  
  if IsDoneIterator(iter) then
    return [];
  fi;
  
  next := NextIterator(iter);
  
  if IsIterator(next) then
    return [ prio+1, next ];
  fi;
  
  return [ [ next ] ];
  
end );

##
InstallGlobalFunction( EvaluateRecursiveIterator,
function(state)
  local name, sem, ch, prio, iter, next, len, leaf, i;
  
  atomic state do
    state.current_number_of_workers := state.current_number_of_workers + 1;
    state.last_assigned_number := state.last_assigned_number + 1;
    name := Concatenation( "worker ", String( state.last_assigned_number ), " in thread #", String( ThreadID( CurrentThread( ) ) ) );
    sem := state.semaphore;
    ch := state.leaf_channel;
  od;
  
  SetRegionName( "", name );
  Info( InfoPtree, 2, "I am ", name, ". Welcome to my local thread." );
  
  while true do
    atomic state do
      state.(name) := MakeImmutable( "Waiting for semaphore" );
    od;
    Info( InfoPtree, 2, "Waiting for semaphore ..." );
    WaitSemaphore(sem);
    atomic state do
      state.(name) := MakeImmutable( "Waiting for semaphore ... DONE" );
    od;
    Info( InfoPtree, 2, "Done." );
    atomic state do
      Info( InfoPtree, 2, "currently ", state.number_of_current_jobs, " jobs awaiting free workers" );
      if state.canceled then
        iter := fail;
      else
        state.(name) := MakeImmutable( "GetPriorityQueue" );
        Info( InfoPtree, 2, "GetPriorityQueue ..." );
	iter := GetPriorityQueue(state.pq);
        state.(name) := MakeImmutable( "GetPriorityQueue ... DONE" );
        Info( InfoPtree, 2, "Done." );
	prio := iter[1];
	iter := iter[2];
        state.(name) := MakeImmutable( "Adopt ..." );
        Info( InfoPtree, 2, "Adopt ..." );
	AdoptObj(iter);
        state.(name) := MakeImmutable( "Adopt ... DONE" );
        Info( InfoPtree, 2, "Done." );
      fi;
    od;
    if iter = fail then
      atomic state do
        state.(name) := MakeImmutable( "Terminated!" );
      od;
      return;
    fi;
    atomic state do
      state.(name) := MakeImmutable( Concatenation( "Computing at priority level ", String( prio ), " ..." ) );
    od;
    Info( InfoPtree, 2, "Computing ..." );
    next := NextRecursiveIterator(prio, iter);
    Info( InfoPtree, 2, "Done." );
    atomic state do
      state.(name) := MakeImmutable( Concatenation( "Computing at priority level ", String( prio ), " ... DONE" ) );
    od;
    len := Length(next);
    atomic state do
      
      state.WallTime := state.WallTime_func();
      state.CPUTimes := state.CPUTimes_func();
      
      if len = 0 then # next = [ ], the iterateor is done without producing leaves
        
        state.number_of_current_jobs := state.number_of_current_jobs - 1;
        
      elif len = 1 then # next = [ [ leaf ] ], the iterator has found a leaf
        
        ## write produced leaf to the channel
        state.(name) := MakeImmutable( "Sending a leaf to channel ..." );
        Info( InfoPtree, 2, "Sending a leaf to channel ..." );
        SendChannel(ch, [ next[1][1], state.WallTime.total, state.CPUTimes.total ] );
        state.(name) := MakeImmutable( "Sending a leaf to channel ... DONE" );
        Info( InfoPtree, 2, "Done." );
        
        state.number_of_leaves := state.number_of_leaves + 1;
        
        ## return iterator to priority queue
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ..." ) );
        Info( InfoPtree, 2, "return iterator of level ", prio, " to priority queue ..." );
        InsertPriorityQueue(state.pq, prio, iter);
        SignalSemaphore(sem);
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
      elif len = 2 then # next = [ prio, iter ] -> next task step
        
        ## insert next iterator into priority queue
        state.(name) := MakeImmutable( Concatenation( "insert next iterator of level ", String( next[1] ), " in priority queue ..." ) );
        Info( InfoPtree, 2, "insert next iterator of level ", next[1], " in priority queue ..." );
        InsertPriorityQueue(state.pq, next[1], next[2]);
        SignalSemaphore(sem);
        state.(name) := MakeImmutable( Concatenation( "insert next iterator of level ", String( next[1] ), " in priority queue ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
        ## return iterator to priority queue
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ..." ) );
        Info( InfoPtree, 2, "return iterator of level ", prio, " to priority queue ..." );
        InsertPriorityQueue(state.pq, prio, iter);
        SignalSemaphore(sem);
        state.(name) := MakeImmutable( Concatenation( "return iterator of level ", String( prio ), " to priority queue ... DONE" ) );
        Info( InfoPtree, 2, "Done." );
        
	state.number_of_current_jobs := state.number_of_current_jobs + 1;
        
      fi;
      
      ## the first worker who figures out that there are no jobs left
      ## (this implies that no other worker is busy) should send
      ## fail to the channel and help all workers finish by
      ## increasing the work semaphore `number_of_current_jobs' times.
      if state.number_of_current_jobs = 0 then
        SendChannel(ch, fail);
        SendChannel(ch, [ state.StartTimeStamp, state.WallTime.total, state.CPUTimes.total ]);
        for i in [ 1 .. state.current_number_of_workers ] do
	  SignalSemaphore(sem);
	od;
      fi;
    od;
  od;
end );

##
InstallGlobalFunction( LaunchWorkers,
function( evaluate_function, state )
  local n, i, worker;
  
  atomic state do
    n := state.maximal_number_of_workers - state.current_number_of_workers;
    for i in [ 1 .. n ] do
      worker := CreateThread(evaluate_function, state);
      Add( state.threads, worker );
    od;
  od;
end );

##
InstallGlobalFunction( ParallelyEvaluateRecursiveIterator,
function(state, nworkers, iter, ch)
  local sem, locally_uniform, worker, i, w;
  
  for i in NamesOfComponents( state ) do
      Unbind( state.(i) );
  od;
  
  sem := CreateSemaphore();
  
  if IsBound( iter!.locally_uniform ) and iter!.locally_uniform = true then
    locally_uniform := true;
  else
    locally_uniform := false;
  fi;
  
  state.pq := [[iter]];
  state.semaphore := sem;
  state.leaf_channel := ch;
  state.number_of_current_jobs := 1;
  state.number_of_leaves := 0;
  state.canceled := false;
  state.threads := [ ];
  state.current_number_of_workers := 0;
  state.last_assigned_number := 0;
  state.maximal_number_of_workers := nworkers;
  
  state.StartTimeStamp := GetTimeOfDay();
  
  state.startWallTime := IO_gettimeofday();
  state.startWallTime.total := 1000 * state.startWallTime.tv_sec + Int( Float( state.startWallTime.tv_usec / 1000 ) );
  state.WallTime_func :=
    function( )
      local WallTime;
      WallTime := IO_gettimeofday();
      WallTime.total :=  1000 * WallTime.tv_sec + Int( Float( WallTime.tv_usec / 1000 ) ) - state.startWallTime.total;
      return WallTime;
  end;
  
  state.startCPUTimes := Runtimes();
  state.startCPUTimes.total := state.startCPUTimes.system_time + state.startCPUTimes.system_time_children + state.startCPUTimes.user_time + state.startCPUTimes.user_time_children;
  state.CPUTimes_func :=
    function( )
      local CPUTimes;
      CPUTimes := Runtimes();
      CPUTimes.total := CPUTimes.system_time + CPUTimes.system_time_children + CPUTimes.user_time + CPUTimes.user_time_children - state.startCPUTimes.total;
      return CPUTimes;
  end;
  
  ShareInternalObj(state,"state region");
  
  if locally_uniform then
    LaunchWorkers( EvaluateLocallyUniformRecursiveIterator, state );
  else
    LaunchWorkers( EvaluateRecursiveIterator, state );
  fi;
  
  SignalSemaphore(sem);
  
  return MakeReadOnlyObj( rec(
    shutdown := function()
      atomic state do
        state.canceled := true;
        for i in [ 1 .. state.current_number_of_workers ] do
	  SignalSemaphore(sem);
	od;
	SendChannel(ch, fail);
	for w in state.threads do
	  WaitThread(w);
	od;
      od;
    end
  ));
end );
