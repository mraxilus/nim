## Turning a body, moment by moment, until something gives.
##
##   A turn is not a pose: it is a path of them.  From a rest that holds, one
##     body is turned a fiftieth of a turn at a time and the arms follow by
##     small moves from where they were -- what a dancer's arms do, which is
##     not the same as the most comfortable pose at each angle taken fresh.
##     The predecessor of this module learnt the same lesson about rope: a
##     shortest path has no memory, and a solver that always re-minimises can
##     never report an arm as wound.
##   Where no small move holds, the step is halved down to a two-hundredth
##     for the angle, and that is the block.  Then the pose is sought afresh
##     at the failed angle: if one exists and is only a step's motion away
##     the turn goes on from it, marked as re-seeded -- an elbow flipping
##     over, say -- and if it exists but is far, the block stands and the
##     report says a pose could hold there if the arms were re-organised.
##     That double report is the honest one: the carried pose is what the
##     dance does, the found pose is what a still picture allows.
##     Cost: the block depends on the path, so the same angle reached another
##       way could hold.  Accepted -- that is what a block is.
##   Every pose the sweep carries is carried with its verdict, found once
##     when the pose was; and the sweeps of different holds, which share
##     nothing, are run side by side on what cores there are.

{.experimental: "strictFuncs".}

import std/options

import ./[body, read, solve]


type
  Moment* = object ## The couple at one turn of the sweep.
    turn*: float ## Turns from the rest, signed.
    state*: State
    verdict*: Verdict
    reseeded*: bool ## Reached by a fresh search where no small move held.

  Block* = object ## Where a sweep stopped one way.
    at*: float ## Turns reached; `most` where nothing stopped it.
    stopped*: bool
    why*: Verdict ## What fails a step beyond, when stopped.
    foundAnyway*: bool ## Whether a pose exists a step beyond, re-organised.

  Sweep* = object ## A hold turned as far as it goes each way.
    who*: Body
    rest*: State
    restHolds*: bool
    moments*: seq[Moment] ## In ascending turn, the rest among them.
    neg*, pos*: Block
    step*: float


const
  STEP* = 0.02 ## Turns per moment of the sweep.
  SUBSTEPS = 4 ## Small moves per moment: an arm sliding round a flank needs
               ## the flank to move a little at a time.
  CREEP* = STEP / SUBSTEPS.float ## Turns per small move: the most a body is
               ## turned before the arms are asked to follow, here and on
               ## the page, which carries its sliders the same way.
  SETTLING = 0.05 ## The comfort a fresh pose must gain to be taken over the
                  ## carried one, plus one unit per metre a joint would jump:
                  ## arms do not flip over for nothing.
  MOST* = 2.5 ## Turns swept each way looking for a block.


func atTurn(rest: State; who: Body; turn: float): State =
  result = rest
  result.stance = turned(rest.stance, who, turn)


func crept(rest: State; who: Body; here: Solved; fromTurn, toTurn: float):
    tuple[got: Solved, turn: float] =
  ## Follow from `here` at `fromTurn` towards `toTurn` in small moves; where
  ## it gets to, which is `toTurn` unless a move failed.
  result = (here, fromTurn)
  for i in 1 .. SUBSTEPS:
    let
      t = fromTurn + (toTurn - fromTurn) * i.float / SUBSTEPS.float
      next = followed(atTurn(rest, who, t), result.got.state)
    if next.isNone:
      return
    result = (next.get, t)


func momentOf(turn: float; got: Solved; reseeded = false): Moment =
  Moment(turn: turn, state: got.state, verdict: got.verdict, reseeded: reseeded)


func sweptWay(rest: Solved; who: Body; sign, most: float;
              moments: var seq[Moment]): Block =
  ## Turn one way from a solved rest, adding the moments found.
  ##   At every moment the pose found afresh is taken where the arms go
  ##     round the bodies the same way as before and it is enough more
  ##     comfortable to be worth the move; otherwise the arms are carried on
  ##     by small moves, and where no small move holds the turn is blocked.
  var
    here = rest
    t = 0.0
  while abs(t) < most - 1e-9:
    let
      tn = t + sign * STEP
      sn = atTurn(rest.state, who, tn)
      fresh = settled(sn)
      got = crept(rest.state, who, here, t, tn)
      carried = abs(got.turn - tn) < 1e-9
    if fresh.isSome and
       sameRoute(here.state, here.verdict, fresh.get.state, fresh.get.verdict) and
       sameCrossings(here.state, here.verdict, fresh.get.state, fresh.get.verdict) and
       (not carried or fresh.get.verdict.cost <
          got.got.verdict.cost - SETTLING - jump(got.got.verdict, fresh.get.verdict)):
      here = fresh.get
      t = tn
      moments.add momentOf(t, here, reseeded = not carried)
      continue
    if carried:
      here = got.got
      t = tn
      moments.add momentOf(t, here)
      continue
    # No small move holds.  Before calling it a block, look harder for a
    # pose the arms could take: the grid is coarse and a corner is narrow.
    let stuck = got.got
    let finer = settled(sn, fine = true)
    if finer.isSome and
       sameRoute(stuck.state, stuck.verdict, finer.get.state, finer.get.verdict) and
       sameCrossings(stuck.state, stuck.verdict, finer.get.state, finer.get.verdict):
      here = finer.get
      t = tn
      moments.add momentOf(t, here, reseeded = true)
      continue
    if abs(got.turn - t) > 1e-9:
      moments.add momentOf(got.turn, stuck)
    return Block(at: abs(got.turn), stopped: true,
                 why: reason(atTurn(rest.state, who, got.turn + sign * STEP / SUBSTEPS.float),
                             stuck.state),
                 foundAnyway: fresh.isSome or finer.isSome)
  Block(at: most, stopped: false)


const
  TRIES = 4 ## Rests tried before the sweep.
  TRIAL = 0.30 ## Turns each way a rest is tried for.


func setUp(rest: State; who: Body): Option[Solved] =
  ## The rest to sweep from: of the few distinct rests the search settles
  ## on, the one that turns furthest in a short trial each way, and the
  ## least strained where two go equally far.
  ##   A couple set a hold up for the turn they are about to do; nothing
  ##     here is tuned, only chosen among poses that all hold at rest.
  var arranged = rest
  arranged.overhead = true
  arranged.turning = who
  let all = restingsWith(arranged, fine = true)
  var
    bestScore = -Inf
  for i in 0 ..< min(TRIES, all.len):
    var
      negs, poss: seq[Moment]
      strain = 0.0
    let
      n = sweptWay(all[i], who, -1.0, TRIAL, negs)
      p = sweptWay(all[i], who, 1.0, TRIAL, poss)
    for m in negs: strain = max(strain, m.verdict.strain)
    for m in poss: strain = max(strain, m.verdict.strain)
    let score = n.at + p.at - 0.1 * strain
    if score > bestScore:
      bestScore = score
      result = some(all[i])


func swept*(rest: State; who: Body; most = MOST): Sweep =
  ## Turn `who` from the rest as far as it goes each way.
  result.who = who
  result.step = STEP
  let solved = if rest.params.len == rest.links.len:
                 some(Solved(state: rest, verdict: evaluate(rest)))
               else: setUp(rest, who)
  result.restHolds = solved.isSome
  if solved.isNone:
    result.rest = rest
    result.neg = Block(at: 0.0, stopped: true)
    result.pos = Block(at: 0.0, stopped: true)
    return
  result.rest = solved.get.state
  var neg, pos: seq[Moment]
  result.neg = sweptWay(solved.get, who, -1.0, most, neg)
  result.pos = sweptWay(solved.get, who, 1.0, most, pos)
  for i in countdown(neg.len - 1, 0):
    result.moments.add neg[i]
  result.moments.add momentOf(0.0, solved.get)
  result.moments.add pos


func limit*(sw: Sweep; sign: float): float =
  ## Turns reached that way.
  if sign < 0.0: sw.neg.at else: sw.pos.at


func at*(sw: Sweep; turn: float): Option[Moment] =
  ## The moment nearest a turn, or none past a block.
  if sw.moments.len == 0 or turn < -sw.neg.at - 1e-9 or turn > sw.pos.at + 1e-9:
    return none(Moment)
  var best = 0
  for i in 1 ..< sw.moments.len:
    if abs(sw.moments[i].turn - turn) < abs(sw.moments[best].turn - turn):
      best = i
  some(sw.moments[best])


#[ Many At Once ]#


type Job* = object ## One sweep to run: a hold, who turns, how far.
  rest*: State
  who*: Body
  most*: float


when defined(js) or not compileOption("threads"):
  proc sweptAll*(jobs: openArray[Job]): seq[Sweep] =
    ## Every job's sweep, in the jobs' order, one after another.
    for job in jobs:
      result.add swept(job.rest, job.who, job.most)
else:
  import std/[atomics, cpuinfo, typedthreads]

  type Work = object ## What a worker thread is handed.
    jobs: ptr UncheckedArray[Job]
    done: ptr UncheckedArray[Sweep]
    n: int
    next: ptr Atomic[int]

  proc worker(w: Work) {.thread.} =
    ## Take the next job not yet taken, sweep it, and put the sweep in its
    ## slot, until there are none.
    while true:
      let i = w.next[].fetchAdd(1)
      if i >= w.n:
        break
      w.done[i] = swept(w.jobs[i].rest, w.jobs[i].who, w.jobs[i].most)

  proc sweptAll*(jobs: openArray[Job]): seq[Sweep] =
    ## Every job's sweep, in the jobs' order, run on as many threads as
    ## there are cores.
    ##   Each sweep is a pure function of its job and touches nothing
    ##     shared, so the threads share only the counter of the next job;
    ##     the slot each writes is its own until every thread has joined.
    result = newSeq[Sweep](jobs.len)
    if jobs.len == 0:
      return
    var
      owned = @jobs
      next: Atomic[int]
      threads = newSeq[Thread[Work]](min(jobs.len, max(1, countProcessors())))
    let w = Work(jobs: cast[ptr UncheckedArray[Job]](owned[0].addr),
                 done: cast[ptr UncheckedArray[Sweep]](result[0].addr),
                 n: jobs.len, next: next.addr)
    for t in threads.mitems:
      createThread(t, worker, w)
    joinThreads(threads)
