Message Passing (and Dropping) Protocol Simulator
=================================================

Wouldn't it be great if you could:

* pick up a distributed algorithms textbook (Nancy Lynch's is my
  favorite) or a research paper or a crazy idea scribbled in a notebook
  for some message passing protocol, then...
* write a small amount of code to implement the algorithm, then...
* run a simulator to tell you if it works?

Ja, those things exist today.  But there are things to be careful of,
including but not limited to:

1. What language are you writing your algorithm in?
2. What language are you verifying the algorithm's properties in?
3. Can the protocol simulator control process scheduling patterns?
   (Irregular scheduling is far more interesting than
   regular/consistent scheduling.)
4. Can the protocol simulator simulate dropped/lost messages?
   (Most protocols do pretty well in perfect environments.  It's much
   more interesting to see what a protocol does when it starts
   dropping messages.)
5. Can the simulator explore all possible scheduling and message
   dropping states to verify that my protocol is correct.

This message passing simulator attempts to address almost all of the
above list.

1. We use Erlang.  It's a nice, high-level language that's frequently
   used for distributed algorithms anyway.  If you're using Erlang,
   it's not as useful to simulate your protocol outside of Erlang and
   then reimplement it in Erlang.
2. We use Erlang also.  High level languages make clear expression of
   your protocol's desired properties pretty easy.
3. Yes.  We use the QuickCheck tool to simulate a token-based
   scheduler, where QuickCheck generates random lists of tokens.  The
   scheduler is as fair or as unfair as you wish.
   There is nothing in the implementation (that I know of) that would
   prevent the use of PropEr for generating any of the test cases
   within the simulator.  I simply haven't had time to try using
   PropEr yet.
4. Yes.  We use QuickCheck again to specify when network partitions
   happen during a simulated test run: For none/some/many `{t0,t1,A,B}`,
   then between simulated time **t0** and **t1**, any message from a process
   in set **A** that sent to a process in set **B** will be dropped.
5. No.  Exhaustive exploration of the entire state space is beyond the
   scope of this tool.  However, it's my hope that this tool points
   the way for something similarly easy for
   [McErlang](https://babel.ls.fi.upm.es/trac/McErlang/) which **is**
   capable of performing full state space exploration.

How to run simulated protocols
------------------------------

    $ cd /path/to/top/of/msgdropsim
    $ make
    $ erl -pz ./ebin
    [... Erlang VM starts up]
    > eqc:quickcheck(slf_msgsim_qc:prop_simulate(echomany_sim, [])).

Also: See the top of each `.erl` file in the `src` directory for
instructions or pointers to instructions.

General usage:

    eqc:quickcheck(slf_msgsim_qc:prop_simulate(SimModuleName, OptionsList)).

* `SimModuleName` is a protocol simulation implementation
module such as `echo_sim` or `distrib_counter_2phase_vclocksetwatch`.
* `OptionsList` is a list of zero or more of the following options:
<pre>
    [{min_clients, N}, {max_clients, M},  %% defaults: N=1, M=9
     {min_servers, N}, {max_servers, M},  %% defaults: N=1, M=9
     disable_partitions,                  %% disable network partitions
     disable_delays                       %% disable message delays
     {min_keys, N},                       %% typically not implemented
     {max_keys, N},                       %% typically not implemented
     crash_report,                        %% enable verbose report upon crash
     {stop_step, N}]                      %% stop execution at step N
</pre>

For example:

    eqc:quickcheck(slf_msgsim_qc:prop_simulate(distrib_counter_2phase_vclocksetwatch_sim, [])).

By default, QuickCheck will run 100 random test cases.  For a protocol
simulation, that usually isn't enough cases to find bugs in even a
simple protocol.

* The argument to `eqc:quickcheck/1` is a property.
* The return value of `slf_msgsim_qc:prop_simulate(SimModuleName, OptionsList)`
  is a property.
  * So the example above,
    `eqc:quickcheck(slf_msgsim_qc:prop_simulate(SimModuleName,
    OptionsList)).`, works as you'd expect.
* If you wish to run 5,000 test cases with a property **Property**, then
  use the construct `eqc:quickcheck(eqc:numtests(5000, Property)).`
* If you wish to make each individual test case longer, i.e., to
  contain longer sequences of protocol operations, use the construct
  `eqc:quickcheck(eqc_gen:resize(R, Property)).` where **R** is an integer
  larger than 40.  The effect seems to be exponential: test cases with
  **R=100** are much, much longer than tests that use **R=50**.
* The `resize()` and `numtests()` wrappers can be used together, e.g.,
  `eqc:quickcheck(eqc:numtests(5000, eqc_gen:resize(60, Property)))`

For example, to run 10,000 test cases of the
`distrib_counter_2phase_vclocksetwatch_sim` simulator:

    eqc:quickcheck(eqc:numtests(10*1000,slf_msgsim_qc:prop_simulate(distrib_counter_2phase_vclocksetwatch_sim, [{max_clients,9}, {max_servers,9}]))).


Describing the evolution of two flawed protocols
------------------------------------------------

The simulator source contains code for simulating two protocols:

* An echo service, one flawed and one ok.
  * The source for these are `echo_bad1_sim.erl` and `echo_sim.erl`,
    respectively.
* A distributed counter service, where all clients are supposed to
  generate strictly-increasing counters.  There are five variations of
  the protocol; all of them are buggy.
  * The sources for these are `distrib_counter_bad1_sim.erl` through
    `distrib_counter_bad5_sim.erl`.

All of the buggy simulator code in a file `foo.erl` has a
corresponding text file called `foo.txt` which contains:

* Instructions on how to run the test case
* Output from the test case
* Annotations within the output, marked by `%%` characters, that help
  explain what the output means.

The `foo.txt` file has annotated
simulator output and discussion of what's wrong with each
implementation, e.g. `echo_bad1_sim.txt` and
`distrib_counter_bad1_sim.txt`.

For the distributed counter simulations, it can be instructive to use
"diff" to compare each implementation, in sequence, to see what
changed.

* `diff -u distrib_counter_bad1_sim.erl distrib_counter_bad2_sim.erl`
* `diff -u distrib_counter_bad2_sim.erl distrib_counter_bad3_sim.erl`
* `diff -u distrib_counter_bad3_sim.erl distrib_counter_bad4_sim.erl`
* `diff -u distrib_counter_bad4_sim.erl distrib_counter_bad5_sim.erl`

How the simulator works
-----------------------

TODO Finish this section

The simulator attempts to maintain Erlang message passing semantics.
Those semantics are not formally documented but can loosely be
described as "send and pray", i.e. no guarantee that any message will
be delivered.  In the case where process **X** sends messages `A` and
`B` to process **Y**, if **Y** receives both messages `B` and `A`,
then message `A` will be delivered before `B`.  (I hope I got that
right ... if not, the Async Message Passing Police will come and
arrest me.)

* Write a callback module
  * `gen_initial_ops/4` The simulator scheduler sends messages from
     created by this generator to each of the simulated processes.
     QuickCheck will randomly choose some number of client & server
     processes for each test case.
  * `gen_client_initial_states/2`
     Generate the local process state data for each client process.
  * `gen_server_initial_states/2`
     Generate the local process state data for each server process.
  * `verify_property/11`
     After a simulated test case has run, verify that whatever protocol
     properties should be true are indeed true.  Any failure will cause
     QuickCheck to try to find a smaller-but-still-failing
     counterexample.
* Compile
* Run via `eqc:quickcheck(slf_msgsim_qc:prop_simulate(YourSimModuleName, PropertyList)).`

  * If your test passes 100 test cases, then you probably need to run
    for thousands or even millions of test cases.  Use
    `eqc:numtests()` and/or/both `eqc_gen:resize(N, YourProperty)`
    where `N` is a large number on the range of 50-100.

Future work
-----------

* Finish converting simulator modules to use QuickCheck
  [QuickCheck "Mini"](http://www.quviq.com/news100621.html).  All of the
  older simulator modules were developed using
  [Quviq's](http://www.quviq.com) commercial version of QuickCheck and
  use at least one construct that is not present in the "Mini" version.
  * The big one that I know of is the
    `conjunction([{Label1,Boolean1},{Label2,Boolean2}...])`
     feature.  For use with QuickCheck Mini, that statement can simply be
     replaced with some plain Erlang: `Boolean1 andalso Boolean2 andalso ...`.
* Add support for simulated Erlang monitors, Erlang's method for
  informing processes that messages may have been dropped.
* Investigate integration of message dropping (and perhaps also
  message delaying?) with McErlang.
* There's gotta be some cool opportunities for visualization and
  animation in here....

Contact the author
------------------

Contact Scott Lystig Fritchie via GitHub email or via `slfritchie`
`(at}` `snookles{dot)com`.

