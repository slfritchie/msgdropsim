Message Passing (and Dropping) Protocol Simulator
=================================================

Wouldn't it be great if you could:

* pick up a distributed algorithms textbook (Nancy Lynch's is my
  favorite) or research paper or a crazy idea scribbled in a notebook
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
   happen during a simulated test run: For none/some/many {t0, t1, A, B},
   then between simulated time t0 and t1, any message from a process
   in set A that sent to a process in set B will be dropped.
5. No.  Exhaustive exploration of the entire state space is beyond the
   scope of this tool.  However, it's my hope that this tool points
   the way for something similarly easy for
   [McErlang](https://babel.ls.fi.upm.es/trac/McErlang/) which **is**
   capable of performing full state space exploration.

How to run simulated protocols
------------------------------

TODO Finish this section

See the top of each `.erl` file in the `src` directory for
instructions or pointers to instructions.

All of the buggy simulator code in a file `foo.erl` has a
corresponding text file called `foo.txt` which contains:

* Instructions on how to run the test case
* Output from the test case
* Annotations within the output, marked by `%%` characters, that help
  explain what the output means.

How the simulator works
-----------------------

TODO Finish this section

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
* Run via `eqc:quickcheck(slf_msgsim_qc:prop_simulate(YourSimModuleName, PropertyList)`

  * If your test passes 100 test cases, then you probably need to run
    for thousands or even millions of test cases.  Use
    `eqc:numtests()` and/or/both `eqc_gen:resize(N, YourProperty)`
    where `N` is a large number on the range of 50-100.

Future work
-----------

* Fully implement the delayed message feature.  The framework is
  there, but the only-slightly-tricky bit of maintaining Erlang
  message ordering guarantees needs to be done.
* Add support for simulated Erlang monitors, Erlang's method for
  informing processes that messages may have been dropped.
* Investigate integration of message dropping (and perhaps also
  message delaying?) with McErlang.

Contact the author
------------------

Contact Scott Lystig Fritchie via GitHub email or via `slfritchie`
`(at}` `snookles{dot)com`.

