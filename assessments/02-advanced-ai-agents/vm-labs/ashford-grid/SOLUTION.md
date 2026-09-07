# Model Answer Walk-through: Ashford Grid

Instructor-facing. The full file is `reference-solution/solution.py`. This explains what each
function does, why it is shaped the way it is, and what goes wrong when it is shaped differently.

## The shared plumbing

Three helpers carry the whole file:

```python
def llm_call(system_prompt, user_prompt):
    response = client().chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[{"role": "system", "content": system_prompt},
                  {"role": "user", "content": user_prompt}])
    return (response.choices[0].message.content or "").strip()
```

`_as_json(raw, fallback)` strips a code fence and parses, returning the fallback on a parse failure
rather than raising. `_as_sql(raw)` strips a fence and a trailing semicolon. The client is built
once and cached, which matters only for tidiness, since `make_client()` is cheap.

Three things about this layer are worth naming:

- **`temperature=0.0`** is what the material uses everywhere. It costs nothing here and it is the
  habit to teach.
- **The parse fallback.** Every structured reply in the lecture is guarded the same way, because a
  model that answers in prose must not take the program down. The endpoint in this lab returns
  parseable JSON on the structured paths, so the fallback does not fire during a normal run. It is
  written for the day the reply arrives as a sentence. Asking for JSON mode with
  `response_format={"type": "json_object"}` is another route to a parseable reply, and the endpoint
  accepts that request.
- **The message list is free.** Two messages is the shape the lecture uses, and nothing downstream
  depends on it. A three-message conversation works. So does sending no system message at all, with
  the role prompt folded into the user message. What matters is that the model is told its job and
  shown the inputs.

## Task 1: `critique_query`, the gate

```python
def critique_query(question, candidate_sql):
    raw = llm_call(CRITIQUE_SYSTEM_PROMPT,
                   "Question: %s\n\nSchema:\n%s\n\nCandidate SQL: %s\n\n"
                   "Return your verdict as JSON only."
                   % (question, schema_summary(), candidate_sql))
    verdict = _as_json(raw, {"valid": False, "reason": "the review could not be read"})
    return {"valid": bool(verdict.get("valid")), "reason": str(verdict.get("reason", ""))}
```

Three decisions worth naming in class:

1. **The user message carries the candidate.** The reviewer cannot review what it was not shown, so
   the candidate SQL has to appear in the text of the request, not merely be known to the caller.
2. **The reason is passed through unchanged.** It is not a decoration. Task 2 forwards it verbatim,
   and the repair step keys on the column names inside it. A learner who rewrites the reason into
   their own words strips out the names, and the repair then has nothing specific to act on.
3. **Nothing is executed.** `schema_summary()` reads the catalogue with `get_table_schema`, which is
   not an execution. A review that runs the candidate, even as a harmless probe, has already done
   the thing the review exists to prevent: the unreviewed statement reached the operations database
   before anything approved it.

The failure mode this task teaches: a query can be syntactically fine and still unrunnable.
`SELECT feeder_code, peak_load_mw FROM feeders WHERE capacity_mw > 10` parses, reads plausibly, and
names a column that does not exist. Only a review against the real schema catches it, and the catch
is worth something only before the query runs.

## Task 2: `self_improving_query`, the evaluator-optimizer loop

```python
sql = draft_query(question)
attempts = 0
while attempts < max_attempts:
    verdict = critique_query(question, sql)
    attempts += 1
    if verdict["valid"]:
        return {..., "result": execute_sql(sql), "attempts": attempts, "accepted": True}
    if attempts >= max_attempts:
        break
    sql = refine_query(question, sql, reason=verdict["reason"])
return {..., "result": None, "attempts": attempts, "accepted": False}
```

The loop is the lecture's Workflow 4 with one addition: **execution is inside the accept branch**.
In the notebook's `text2sql_eval_optimize` the query is executed on every pass, because execution is
itself one of the two signals. Here the gate comes first, which is the stricter reading of the same
pattern and the one an operations database wants. You do not run an unreviewed statement against
production to find out whether it is safe.

The counting convention, `attempts` = candidates reviewed, is fixed by the statement precisely
because implementations differ. The count is a property of the definition rather than of the control
flow. A recursive version that passes a `used` counter down, and a loop that consumes a generator of
candidates, both land on 2 for the converging question.

The bound matters as much as the convergence. `"Which feeder has the worst reactive power factor?"`
has no answer in this schema. There is no such column and nothing comparable to substitute, so the
review keeps rejecting and the repair has nothing to work from. That case has to stop at
`max_attempts` and come back with `accepted: False` and no result. The lecture's own words:
*without control logic, agentic systems degrade into open-ended recursion.*

## Task 3: `execute_with_feedback`, the database as ground truth

```python
result = execute_sql(sql)
attempts += 1
if not result.startswith("ERROR:"):
    return {..., "succeeded": True, "error_memory": error_memory}
error = result[len("ERROR:"):].strip()
error_memory.append({"question": question, "failed_sql": sql, "error": error})
sql = refine_query(question, sql, db_error=error, error_memory=error_memory)
```

This is the lecture's `execute_sql_safe` plus `refine_sql(db_error=...)` plus Reflexion-style
`error_memory` in one function. The worked question is chosen so the memory has to do real work: it
has **two** bad column names, and SQLite reports one problem at a time. So the sequence is

```
run  -> no such column: cause_type            (memory: 1 entry)
repair with that error                        -> one name fixed
run  -> no such column: affected_customers    (memory: 2 entries)
repair with that error AND both memory entries -> both names fixed
run  -> cause | total_customers / storm | 18490
```

`attempts` is 3. The second repair request has to carry both errors, not only the newest one. A
learner who forwards the latest failure alone gives the model no record of the fix it already made,
so the repair can reintroduce the first bad name while fixing the second, and the loop runs out of
attempts on a query it had half repaired. That is the difference between a retry and a memory.

`memory_context()` is the lecture's `_build_memory_context()`, last three entries and all. The cap
is there so a long session does not bloat the context, and it is harmless here because this case
has two entries.

The memory does not have to be a list threaded through free functions. A class that holds it as
instance state, with the five callables as methods on that class, satisfies the same contract; that
is the lecture's own `SelfImprovingSQLAgent` shape. Keeping the entries as tuples and converting
them to dicts on the way out works too, since only the returned form is specified.

## Task 4: `route_request`, one decision, then a table

```python
ROUTES = {"outage_lookup": handle_outage_lookup, "capacity_check": handle_capacity_check,
          "load_trend": handle_load_trend, "schema_help": handle_schema_help}

parsed = _as_json(llm_call(ROUTE_SYSTEM_PROMPT, "Request: %s" % request), {...})
category = str(parsed.get("category") or "schema_help")
handler = ROUTES.get(category)
return {"category": category, "result": handler(request)}
```

Structurally identical to `SUPPORT_ROUTES` / `route_support_ticket`. The lesson is the one the
lecture states plainly: *adding a new category requires only adding a new handler function and one
entry in the table.* Control-room operators phrase their requests like this:

- "How long was the north loop down after the storm last month, and how many homes went dark?"
- "Can we hand another twelve megawatts to the Tarrant Quay run without pushing it past its rating?"

Neither contains the word "outage" or "capacity". A chain of keyword tests over words lifted from
the sample requests misroutes both of these, and the desk it then calls does not match the category
it returns. The classifier remains the single point of failure the lecture warns about. The fix the
material suggests, a confidence threshold with escalation below it, is left out of the contract here
so the task stays one concern.

The table does not have to be a literal mapping written out by hand. Building it by stripping
`handle_` off the front of a registry dict's keys is the same dispatch, and so is keying it on a
pair such as `(desk, label)`. What makes it a dispatch table is the lookup, not the literal.

## Task 5: `parallel_guards`, scatter, gather, and a blocking guard

```python
with ThreadPoolExecutor(max_workers=len(GUARD_NAMES)) as pool:
    futures = {pool.submit(run_guard, name, candidate_sql): name for name in GUARD_NAMES}
    for future in as_completed(futures):
        results.append(future.result())
blocked_by = sorted(r["guard"] for r in results if not r["passes"])
return {"blocked": bool(blocked_by), "blocked_by": blocked_by, "guards": results}
```

The lecture's Example A, sectioning, where generation runs while a guard screens and the guard can
block delivery, crossed with the voting critics of section 4.1. The aggregation rule here is
unanimity rather than a majority, because these four guards examine four different things rather
than the same thing from different angles. Any one of them objecting is a real objection.

Two properties of the design:

- **All four run, every time.** There is no short-circuit on the first failure. Short-circuiting
  puts the guards back into a fixed order and throws away the independence that made them
  parallelisable.
- **All four are in flight at once.** Each guard call waits on the endpoint rather than on the CPU,
  so the overlap is available whatever the core count of the VM. A pool with fewer than four workers
  serialises some of them: four tasks over three workers still take two intervals, and over two
  workers they run in pairs. Asking the guards one at a time returns the same verdict and takes four
  times as long, which is the cost this task exists to remove.

The API is a free choice. `as_completed`, `futures.wait(ALL_COMPLETED)`, `pool.map`, and submitting
then reading `.result()` in submission order all give the same overlap, as does pre-binding the
calls with `functools.partial`. Four raw `threading.Thread` objects writing into a `queue.Queue`
with no `concurrent.futures` anywhere is equally acceptable, and either standard-library route is
fine. A `ThreadPoolExecutor()` with no `max_workers` argument also works, because the default size
on any VM this lab runs on is comfortably above four.

## The one place a correct-looking solution can still be wrong

Worth showing learners: the whole layer reimplemented locally, with hand-written rules over the real
schema and no model call anywhere. Its verdicts are often right, its routing is often right, and its
guard aggregation is right, because the schema is small enough to encode by hand.

It has still missed the point of the exercise. The value of this layer is that the *model* produces
the critique, the repair and the classification, conditioned on feedback the program assembles. A
hand-written rule set produces the same answers for this schema and none of the answers for the next
one, and it has no repair step to run when the database reports something the author did not
anticipate.
