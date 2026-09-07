# Module 3 — Type Safety & Validation with Pydantic

> **Which lecture this is.** This is **Lecture 2** of Module 3, per the authoritative
> `modules/03-agentic-ai-systems/markdown/L2_Type_Safety_&_Validation_with_Pydantic.md`. The `M3-L1-`
> filename predates that rule and is **not** the lecture number — see the numbering caveat in
> [`../README.md`](../README.md). Questions carry `[Class 2]` in the notebook.

Five coding questions covering the five places a Pydantic schema does real work in an agent — the
**call envelope** the model produces, the **arguments** each individual tool accepts, the **schema
handed to the model** so it knows what to produce, the **wire hop** where a response leaves one
process and is re-validated in another, and the **cross-field rule** that no single field can see.

Q1, Q2 and Q5 follow the same shape: one `List of Dicts` argument, per-record validation against a
model built at module level, and a `Dictionary` mapping each record's index to `"valid"` or a single
failure token. Q3 runs the boundary in the other direction — models in, JSON Schema out — and Q4
exercises the serializer rather than the validator, grading the exact JSON string Pydantic emits. Each
question is self-contained: they share a scenario but none depends on another. All five are
deterministic and offline: no LLM call, no API key, no network. `pydantic` v2 only.

---

## Q1: Validate a batch of tool-call envelopes at the Pydantic boundary

**Context:** A proposed tool call arrives as an envelope of untrusted strings — a tool `name` the
model picked, and an `arguments` blob it wrote as JSON text. Both halves are guesses. A weak agent
dispatches on the name without checking it against its allowlist, and hands the blob to `json.loads`
without checking that it parses, so a hallucinated tool or a payload the model wrapped in prose
surfaces as a crash deep inside a tool rather than a rejection at the door. One schema at the
entrance turns all of it into a single loggable error.

**Problem Statement:**

Write a function `validate_tool_calls(calls)` that validates a list of proposed tool-call envelope
dictionaries against a fixed schema and reports, per envelope, whether it passes or why it fails.

1. Define one Pydantic (v2) model `ToolCall` for a valid envelope with **exactly** these fields,
   configured to **reject any extra key** (`extra="forbid"`):
   - `name` — `Literal["pay", "get_balance"]`, the allowlist of tools the system offers
   - `arguments` — string, the raw JSON text the model produced
2. Give `ToolCall` a field validator on `arguments` that parses the string with `json.loads` and
   insists it decodes to a JSON **object**: raise `ValueError("bad_json")` if the string is not valid
   JSON, `ValueError("not_an_object")` if it parses into anything else (a list, a number, a bare
   string, `null`), and return the string unchanged when it passes. Do not repair the string first —
   no stripping markdown fences, no pulling the JSON-looking substring out of surrounding prose.
3. For each dictionary in `calls` (in order), validate the **whole dictionary, as received** against
   the model — not a fresh dictionary rebuilt from the fields you care about.
4. On success, the envelope's label is the string `"valid"`. On failure, catch the `ValidationError`
   and take its **first** error:
   - if that error's `type` is `"value_error"`, your validator fired. The label is the bare token you
     raised — `"bad_json"` or `"not_an_object"`. Pydantic carries it in the error's `msg`, not its
     `type`.
   - otherwise the label is that error's `type` value, passed through unchanged — whatever Pydantic
     put there, not a string of your own choosing.
5. Return a dictionary mapping each envelope's 0-based index to its label string.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: calls (list_dict)
    Line 1: N (number of envelopes)
    Next N lines: one JSON object per line, each an envelope as received
```

**Output Format:**

For each test case, print the result of `validate_tool_calls()` on a new line.

**Sample Input:**

```
calls = [
    {"name": "pay",         "arguments": '{"amount": 10, "recipient": "Ada"}'},
    {"name": "os.system",   "arguments": '{"cmd": "rm -rf /"}'},
    {"name": "pay",         "arguments": 'Sure! Here is the JSON: {"amount": 10, "recipient": "Ada"}'},
    {"name": "get_balance", "arguments": '{}'},
    {"name": "pay",         "arguments": '[10, "Ada"]'},
    {"name": "pay"},
    {"name": "pay",         "arguments": '{}', "override_safety": true},
    {"name": "pay",         "arguments": 42}
]
```

**Sample Output:**

```
{0: 'valid', 1: 'literal_error', 2: 'bad_json', 3: 'valid', 4: 'not_an_object', 5: 'missing', 6: 'extra_forbidden', 7: 'string_type'}
```

**Note:** Build the model once at module level, outside the function. Pass each envelope to the model
as it arrived rather than copying the two fields you care about into a fresh dictionary — copying is
what lets an unexpected key slip past `extra="forbid"` unnoticed. Both of your payload rules report
under the same generic `"value_error"` type, so the type alone cannot tell a bad-JSON envelope from a
non-object one — that is exactly why step 4 has you read the token out of the message instead. This
model judges the envelope only: an admitted payload's *keys* are not checked against the tool that
will receive them.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: validate_tool_calls
RETURN TYPE: Dictionary

ARGUMENTS:
1. calls → List of Dicts
```

(`List of Dicts` is an **argument-only** type; the per-envelope results fold into one index-keyed
`Dictionary`, exactly as in the bank's Pydantic questions.)

**Reference Solution:**

```python
import json
from typing import Literal

from pydantic import BaseModel, ConfigDict, ValidationError, field_validator


class ToolCall(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: Literal["pay", "get_balance"]
    arguments: str

    @field_validator("arguments")
    @classmethod
    def arguments_must_decode_to_an_object(cls, v: str) -> str:
        try:
            payload = json.loads(v)
        except json.JSONDecodeError:
            raise ValueError("bad_json")
        if not isinstance(payload, dict):
            raise ValueError("not_an_object")
        return v


def validate_tool_calls(calls: list) -> dict:
    result = {}
    for i, call in enumerate(calls):
        try:
            ToolCall.model_validate(call)
            result[i] = "valid"
        except ValidationError as e:
            err = e.errors()[0]
            if err["type"] == "value_error":
                result[i] = err["msg"].removeprefix("Value error, ")
            else:
                result[i] = err["type"]
    return result
```

**Test Cases —** `in.txt`

```
2
8
{"name": "pay", "arguments": "{\"amount\": 10, \"recipient\": \"Ada\"}"}
{"name": "os.system", "arguments": "{\"cmd\": \"rm -rf /\"}"}
{"name": "pay", "arguments": "Sure! Here is the JSON: {\"amount\": 10, \"recipient\": \"Ada\"}"}
{"name": "get_balance", "arguments": "{}"}
{"name": "pay", "arguments": "[10, \"Ada\"]"}
{"name": "pay"}
{"name": "pay", "arguments": "{}", "override_safety": true}
{"name": "pay", "arguments": 42}
9
{"name": "get_balance", "arguments": "{\"amount\": 1}"}
{"name": "transfer_funds", "arguments": "{}"}
{"name": "pay", "arguments": "not json at all"}
{"name": "pay", "arguments": "null"}
{"name": "PAY", "arguments": "{}"}
{"name": "pay", "arguments": "  {\"x\": 1}  "}
{"name": "get_balance"}
{"name": "get_balance", "arguments": "{\"a\": 1}", "id": "call_9"}
{"name": "pay", "arguments": "```json\n{\"amount\": 10, \"recipient\": \"Ada\"}\n```"}
```

**Test Cases —** `out.txt`

```
{0: 'valid', 1: 'literal_error', 2: 'bad_json', 3: 'valid', 4: 'not_an_object', 5: 'missing', 6: 'extra_forbidden', 7: 'string_type'}
{0: 'valid', 1: 'literal_error', 2: 'bad_json', 3: 'not_an_object', 4: 'literal_error', 5: 'valid', 6: 'missing', 7: 'extra_forbidden', 8: 'bad_json'}
```

**Grader Notes:**

- Both cases were **executed** against the reference solution (Python 3.14, `pydantic` 2.13.4,
  standard library otherwise); the `out.txt` lines above are the actual program output.
- The error-type labels are Pydantic **v2** identifiers — pin Pydantic v2. If they prove brittle
  across patch releases, grade on the valid/invalid split plus the two custom tokens (`bad_json`,
  `not_an_object`), which are ours and therefore stable.
- **The statement deliberately does not enumerate the pass-through error types.** The learner forwards
  `err["type"]` and never authors those strings, so a list would only invite them to build a
  defect→label mapping that must not exist. For reference, the complete label vocabulary across both
  cases is `valid`, the two tokens the learner *does* author (`bad_json`, `not_an_object`), and four
  Pydantic-generated types: `literal_error`, `missing`, `extra_forbidden`, `string_type` (verified —
  nothing else appears). All four are visible in the sample output against their sample inputs, so the
  learner can still self-check without being handed a vocabulary. Q2 is the same, with seven generated
  types: `missing`, `float_parsing`, `greater_than`, `less_than_equal`, `string_too_short`,
  `string_too_long`, `extra_forbidden`.
- Dictionary key order is not significant; compare values by key with exact string comparison.
- **Any way of recovering the token from `msg` is acceptable.** The statement fixes the *label*, not
  the extraction technique, and all three natural readings were run and agree on every case:
  `msg.removeprefix("Value error, ")` (what the reference does), `msg.split("Value error, ")[-1]`,
  and substring-testing `msg` against the two known tokens. Do not mark down a working variant.
  The substring form is the only one that would survive Pydantic changing the `"Value error, "`
  prefix — irrelevant while the version is pinned, but the reason to prefer it if this question is
  ever unpinned.
- Each envelope carries **exactly one** defect, so `.errors()[0]` is unambiguous. Field-level
  validators run in field-declaration order, so a bad `name` is reported before a bad `arguments`.
- Case 1 covers a clean envelope, a hallucinated name, a prose-wrapped payload, an empty payload, a
  JSON-array payload, a missing `arguments` field, an extra envelope key, and a non-string payload.
  Case 2 adds a second unknown name, unparseable text, `null`, wrong-case `"PAY"`, a payload padded
  with whitespace (which `json.loads` accepts), a missing `arguments` on the other tool, a
  realistic stray `"id"` key, and a ```` ```json ````-fenced payload.
- The two "repair" temptations are deliberately split across the cases, because they are **not** the
  same bug and one does not catch the other: case 1 call 2 is prose-wrapped (defeated only by
  substring-extracting the JSON), and case 2 call 8 is markdown-fenced (defeated only by a fence
  stripper). A solution carrying just one of the two repairs passes the other case cleanly.
- Wrong readings that were run and confirmed to fail:
  - **`name: str` with no `Literal` allowlist** — case 1 call 1 becomes `valid`, and case 2 admits
    both `transfer_funds` and `PAY`.
  - **No `@field_validator` on `arguments`** (accepting any string) — case 1 calls 2 and 4 become
    `valid`, and case 2 calls 2, 3 and 8 become `valid`.
  - **Stripping markdown fences** (porting the source walkthrough's fence-stripping helper) — case 2
    call 8 becomes `valid`. Note this reading leaves **both** cases otherwise untouched, case 1
    included, so case 2 call 8 is the only thing standing between it and a full score — do not drop
    that call.
  - **Regexing the first `{...}` blob out of the prose** — case 1 call 2 becomes `valid`. This is a
    *different* wrong reading from the one above; a fence stripper does not make call 2 valid, and
    a substring extractor does not make case 2 call 8 valid.
  - **`extra="ignore"` on the envelope** — case 1 call 6 and case 2 call 7 become `valid`.
  - **Labelling with `err["type"]` unconditionally** — case 1 calls 2 and 4 and case 2 calls 2, 3
    and 8 all collapse to `value_error`, losing the distinction between a bad payload and a
    non-object one. This is the reading the statement's step 4 exists to rule out.
  - **Copying `name`/`arguments` into a fresh dict instead of validating the envelope as received** —
    case 1 call 6 becomes `valid` and call 5 reports `string_type` instead of `missing`; case 2 call 7
    becomes `valid` and call 6 reports `string_type` instead of `missing`.
    **Note for whoever sets the paper:** the source walkthrough builds its envelope exactly this way
    (`model_validate({"name": ..., "arguments": ...})`), so its own `extra="forbid"` can never fire.
    This question deliberately exercises that setting, which is why the statement says "the **whole
    dictionary**, as received" and the Note repeats it. If you would rather not penalise a learner who
    ports that construction verbatim, drop call 6 from case 1 and call 7 from case 2 — but note that
    calls 5 (case 1) and 6 (case 2) still diverge on `missing` vs `string_type`, so dropping the two
    extra-key calls does not fully neutralise the reading.
- **Relation to the bank's Pydantic questions:** intentionally the same four-step shape as the bank's
  Q1 (`validate_records`), and it borrows the bank Q2 device of a `ValueError("<token>")` raised
  inside a validator. What is new is the subject — a tool-call **envelope** rather than a flat
  record — plus the `Literal` allowlist and the payload-parseability rule, neither of which the bank
  covers.
- No network, no LLM call, no API key: the envelopes are fixtures, so the question is fully
  reproducible offline.

---

## Q2: One argument schema per tool — the right schema for the right tool

**Context:** An agent exposes two tools: `pay`, which moves money and needs a bounded amount and a
plausible recipient, and `get_balance`, which takes no arguments at all — so *any* key in its payload
is an unexpected one. Validate both against one shared model and each tool inherits the other's
rules. The production shape is a registry: each tool name maps to its own input schema, and a payload
is checked against the schema for the tool that will actually receive it.

**Problem Statement:**

Write a function `validate_tool_args(records)` that validates each tool call's arguments against that
tool's own schema and reports, per record, whether it passes or why it fails.

1. Define two Pydantic (v2) models, both configured to **reject extra keys** (`extra="forbid"`):
   - `PayArgs` — also strip surrounding whitespace from string fields
     (`str_strip_whitespace=True`). Its fields are `amount` (float, `gt=0`, `le=10_000`) and
     `recipient` (string, `min_length=1`, `max_length=64`), with all four bounds declared as
     `Field(...)` constraints rather than checked by hand.
   - `GetBalanceArgs` — **no fields at all**, because that tool takes no arguments.
2. Register them in a dictionary mapping the tool name `"pay"` to `PayArgs` and `"get_balance"` to
   `GetBalanceArgs`.
3. Each dictionary in `records` has a `"tool"` key — always either `"pay"` or `"get_balance"` — and an
   `"args"` key holding that call's arguments as a dictionary. For each record (in order), look up the
   schema registered for its `"tool"` and validate its `"args"` against **that** schema.
4. On success, the record's label is the string `"valid"`. On failure, catch the `ValidationError` and
   take the **first** error's `type` value, passed through unchanged as the label — whatever Pydantic
   put there, not a string of your own choosing.
5. Return a dictionary mapping each record's 0-based index to its `"valid"`/error-type string.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: records (list_dict)
    Line 1: N (number of records)
    Next N lines: one JSON object per line, each with a "tool" and an "args" key
```

**Output Format:**

For each test case, print the result of `validate_tool_args()` on a new line.

**Sample Input:**

```
records = [
    {"tool": "pay",         "args": {"amount": 10, "recipient": "Ada"}},
    {"tool": "pay",         "args": {"amount": "one hundred", "recipient": "Ada"}},
    {"tool": "pay",         "args": {"amount": 10}},
    {"tool": "pay",         "args": {"amount": 1, "recipient": "Ada", "override_safety": true}},
    {"tool": "pay",         "args": {"amount": -1000000, "recipient": "Ada"}},
    {"tool": "get_balance", "args": {}}
]
```

**Sample Output:**

```
{0: 'valid', 1: 'float_parsing', 2: 'missing', 3: 'extra_forbidden', 4: 'greater_than', 5: 'valid'}
```

**Note:** Build both models and the registry once at module level, outside the function. Select the
schema by the record's `"tool"` — the two models are not interchangeable, and validating every record
against the same one is the bug this question is about. Lax coercion stays on, so a string like
`"100"` in a `float` field is accepted and converted; only the constraints you declared reject a
value.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: validate_tool_args
RETURN TYPE: Dictionary

ARGUMENTS:
1. records → List of Dicts
```

(`List of Dicts` is an **argument-only** type, and each record's `"args"` value is a nested object
inside it; the per-record results fold into one index-keyed `Dictionary`.)

**Reference Solution:**

```python
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, ValidationError


class PayArgs(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    amount: Annotated[float, Field(gt=0, le=10_000)]
    recipient: Annotated[str, Field(min_length=1, max_length=64)]


class GetBalanceArgs(BaseModel):
    model_config = ConfigDict(extra="forbid")


TOOL_REGISTRY: dict = {
    "pay": PayArgs,
    "get_balance": GetBalanceArgs,
}


def validate_tool_args(records: list) -> dict:
    result = {}
    for i, rec in enumerate(records):
        args_schema = TOOL_REGISTRY[rec["tool"]]
        try:
            args_schema.model_validate(rec["args"])
            result[i] = "valid"
        except ValidationError as e:
            result[i] = e.errors()[0]["type"]
    return result
```

**Test Cases —** `in.txt`

```
2
6
{"tool": "pay", "args": {"amount": 10, "recipient": "Ada"}}
{"tool": "pay", "args": {"amount": "one hundred", "recipient": "Ada"}}
{"tool": "pay", "args": {"amount": 10}}
{"tool": "pay", "args": {"amount": 1, "recipient": "Ada", "override_safety": true}}
{"tool": "pay", "args": {"amount": -1000000, "recipient": "Ada"}}
{"tool": "get_balance", "args": {}}
6
{"tool": "pay", "args": {"amount": 20000, "recipient": "Ada"}}
{"tool": "pay", "args": {"amount": 250.5, "recipient": "  Bob  "}}
{"tool": "pay", "args": {"amount": 1, "recipient": "   "}}
{"tool": "get_balance", "args": {"amount": 1}}
{"tool": "pay", "args": {"amount": "100", "recipient": "Cleo"}}
{"tool": "pay", "args": {"amount": 5, "recipient": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}
```

**Test Cases —** `out.txt`

```
{0: 'valid', 1: 'float_parsing', 2: 'missing', 3: 'extra_forbidden', 4: 'greater_than', 5: 'valid'}
{0: 'less_than_equal', 1: 'valid', 2: 'string_too_short', 3: 'extra_forbidden', 4: 'valid', 5: 'string_too_long'}
```

**Grader Notes:**

- Both cases were **executed** against the reference solution (Python 3.14, `pydantic` 2.13.4); the
  `out.txt` lines above are the actual program output.
- Error-type strings are Pydantic **v2** identifiers — pin Pydantic v2, or grade on the valid/invalid
  split plus the offending field if string-matching proves brittle.
- Dictionary key order is not significant; compare values by key with exact string comparison.
- Each record carries **exactly one** defect, so `.errors()[0]` is unambiguous. In record 3 of case 1
  both declared fields are valid and the only error is the extra key, which is why `extra_forbidden`
  is reported.
- Case 1 covers a clean payment, a wrong type, a missing field, a smuggled key, a negative amount, and
  a legitimate call to the argument-less tool. Case 2 adds the upper bound (`le=10_000`), a
  whitespace-padded recipient that is fine, a whitespace-**only** recipient that is not, an extra key
  aimed at the argument-less tool, lax coercion of `"100"`, and a 65-character recipient.
- Wrong readings that were run and confirmed to fail:
  - **One shared schema instead of a per-tool registry** — case 1 record 5 returns `missing` instead
    of `valid`, and case 2 record 3 returns `missing` instead of `extra_forbidden`. This is the
    question's central check.
  - **`extra="ignore"` on `PayArgs`** — case 1 record 3 returns `valid`.
  - **Omitting `str_strip_whitespace=True`** — case 2 record 2 returns `valid`, because a
    three-space recipient satisfies `min_length=1` unstripped.
  - **Enforcing the bounds with `@field_validator` instead of `Annotated[..., Field(...)]`** — a
    raised `ValueError` reports as `value_error`, not as the specific constraint type, so case 1
    record 4 and case 2 records 0, 2 and 5 all return `value_error`. This is what the statement's
    step 1 (which names the `Field` kwargs) and the Note (which names `Annotated[..., Field(...)]`)
    exist to rule out; both cases catch it, so it cannot slip through on a sample-only check.
  - **Omitting `extra="forbid"` on `GetBalanceArgs`** — case 2 record 3 returns `valid`. The
    argument-less tool is the one place where forgetting the config has no *field* to hide behind.
- **Relation to the bank's Pydantic questions:** the same four-step shape and the same
  `errors()[0]["type"]` reporting device as the bank's Q1 (`validate_records`), which validates every
  record against **one** model. The new idea here is schema *selection* — two models with different
  fields, chosen per record — which neither bank question exercises. If both appear on one paper, the
  error-type reporting device is tested twice.
- No network, no LLM call, no API key: the records are fixtures, so the question is fully reproducible
  offline.

---

## Q3: Publish the schemas — Pydantic models to strict-mode tool specs

**Context:** Validating a tool call after the model makes it is only half the contract. Before the
model can call a tool at all, it has to be told what that tool accepts — and the honest way to tell
it is to generate the JSON Schema from the same Pydantic model that will later validate the call.
A hand-maintained JSON schema drifts from the Python model the moment someone adds a field, and the
drift shows up as a model confidently sending arguments your validator then rejects. A generated
schema cannot drift — but it is not quite what a strict-mode function-calling API will accept, so it
needs a small, exact post-processing pass first.

**Problem Statement:**

Write a function `build_tool_specs(tool_names)` that generates a strict-mode tool specification for
each requested tool from that tool's Pydantic input model.

1. Define these Pydantic (v2) models, using the **exact class names, field names, and field order**
   given — all three surface in the generated schema, so all three are graded. Declare every bound as
   a `Field(...)` constraint rather than checking it by hand, so it reaches the schema:
   - `WeatherIn` — `city` (string) and `unit` (`Literal["celsius", "fahrenheit"]`, defaulting to
     `"celsius"`). No `model_config`.
   - `SearchIn` — configured with `extra="forbid"`; fields are `query` (string, `min_length=1`,
     `max_length=200`) and `top_k` (integer, `ge=1`, `le=10`, defaulting to `3`).
   - `Address` — `city` (string) and `zip` (string). No `model_config`.
   - `ShipIn` — `order_id` (string) and `destination` (an `Address`). No `model_config`.
2. Build a registry dictionary mapping each tool name to its description and its input model — for
   example, name → `(description, model)` tuple. Use these exact names and descriptions; both are
   copied into the output:
   - `"get_weather"` → `"Get current weather for a city."`, `WeatherIn`
   - `"search_web"` → `"Search the web for a query."`, `SearchIn`
   - `"ship_order"` → `"Ship an order to an address."`, `ShipIn`
3. For each name in `tool_names` (in order), generate its input model's JSON Schema with
   `.model_json_schema()`, then walk the generated schema and, at **every** object node anywhere
   inside it — at any depth, wherever they appear — apply the two things strict mode requires that
   the generator does not produce on its own:
   - set `"additionalProperties"` to `False`
   - set `"required"` to a list of **every** key in that node's `"properties"`, in the order they
     appear there, including keys that have a default
   An object node is one whose `"type"` is `"object"` and which has a `"properties"` key. Leave the
   rest of the generated schema exactly as it came out — do not delete, rename, or reorder anything
   else.
4. Wrap each post-processed schema in a spec dictionary shaped exactly like this, with the keys
   inserted in the order shown:

   `{"type": "function", "function": {"name": <tool name>, "description": <registered description>,
   "parameters": <post-processed schema>, "strict": True}}`
5. Return a dictionary mapping each requested tool name to its spec dictionary. If a requested name
   is not in the registry, map it to the string `"unknown_tool"` instead of a spec — a name you have
   no schema for is a name you must not publish.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: tool_names (list_string)
    Line 1: N (list length)
    Next N lines: one string each
```

**Output Format:**

For each test case, print the result of `build_tool_specs()` on a new line.

**Sample Input:**

```
tool_names = ["get_weather", "os.system"]
```

**Sample Output:**

```
{
    'get_weather': {
        'type': 'function',
        'function': {
            'name': 'get_weather',
            'description': 'Get current weather for a city.',
            'parameters': {
                'properties': {
                    'city': {'title': 'City', 'type': 'string'},
                    'unit': {'default': 'celsius', 'enum': ['celsius', 'fahrenheit'], 'title': 'Unit', 'type': 'string'}
                },
                'required': ['city', 'unit'],
                'title': 'WeatherIn',
                'type': 'object',
                'additionalProperties': False
            },
            'strict': True
        }
    },
    'os.system': 'unknown_tool'
}
```

**Note:** Build the models and the registry once at module level, outside the function. Print a
generated schema and read it before you start editing it — where the generator puts a nested model,
and which fields it lists under `"required"`, are both worth seeing for yourself rather than
assuming. The sample output above is indented purely for readability: you return one dictionary, and
the printing is already handled for you.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: build_tool_specs
RETURN TYPE: Dictionary

ARGUMENTS:
1. tool_names → List of Strings
```

(The per-tool specs fold into one name-keyed `Dictionary`; unrecognised names take a plain string
value in the same dictionary rather than a second return value.)

**Reference Solution:**

```python
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field


class WeatherIn(BaseModel):
    city: str
    unit: Literal["celsius", "fahrenheit"] = "celsius"


class SearchIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    query: Annotated[str, Field(min_length=1, max_length=200)]
    top_k: Annotated[int, Field(ge=1, le=10)] = 3


class Address(BaseModel):
    city: str
    zip: str


class ShipIn(BaseModel):
    order_id: str
    destination: Address


TOOL_REGISTRY: dict = {
    "get_weather": ("Get current weather for a city.", WeatherIn),
    "search_web": ("Search the web for a query.", SearchIn),
    "ship_order": ("Ship an order to an address.", ShipIn),
}


def _strictify(node) -> None:
    if isinstance(node, dict):
        if node.get("type") == "object" and "properties" in node:
            node["additionalProperties"] = False
            node["required"] = list(node["properties"].keys())
        for v in node.values():
            _strictify(v)
    elif isinstance(node, list):
        for v in node:
            _strictify(v)


def build_tool_specs(tool_names: list) -> dict:
    specs = {}
    for name in tool_names:
        if name not in TOOL_REGISTRY:
            specs[name] = "unknown_tool"
            continue
        description, input_schema = TOOL_REGISTRY[name]
        schema = input_schema.model_json_schema()
        _strictify(schema)
        specs[name] = {
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": schema,
                "strict": True,
            },
        }
    return specs
```

**Test Cases —** `in.txt`

```
2
2
get_weather
os.system
2
search_web
ship_order
```

**Test Cases —** `out.txt`

```
{'get_weather': {'type': 'function', 'function': {'name': 'get_weather', 'description': 'Get current weather for a city.', 'parameters': {'properties': {'city': {'title': 'City', 'type': 'string'}, 'unit': {'default': 'celsius', 'enum': ['celsius', 'fahrenheit'], 'title': 'Unit', 'type': 'string'}}, 'required': ['city', 'unit'], 'title': 'WeatherIn', 'type': 'object', 'additionalProperties': False}, 'strict': True}}, 'os.system': 'unknown_tool'}
{'search_web': {'type': 'function', 'function': {'name': 'search_web', 'description': 'Search the web for a query.', 'parameters': {'additionalProperties': False, 'properties': {'query': {'maxLength': 200, 'minLength': 1, 'title': 'Query', 'type': 'string'}, 'top_k': {'default': 3, 'maximum': 10, 'minimum': 1, 'title': 'Top K', 'type': 'integer'}}, 'required': ['query', 'top_k'], 'title': 'SearchIn', 'type': 'object'}, 'strict': True}}, 'ship_order': {'type': 'function', 'function': {'name': 'ship_order', 'description': 'Ship an order to an address.', 'parameters': {'$defs': {'Address': {'properties': {'city': {'title': 'City', 'type': 'string'}, 'zip': {'title': 'Zip', 'type': 'string'}}, 'required': ['city', 'zip'], 'title': 'Address', 'type': 'object', 'additionalProperties': False}}, 'properties': {'order_id': {'title': 'Order Id', 'type': 'string'}, 'destination': {'$ref': '#/$defs/Address'}}, 'required': ['order_id', 'destination'], 'title': 'ShipIn', 'type': 'object', 'additionalProperties': False}, 'strict': True}}}
```

**Grader Notes:**

- Both cases were **executed** against the reference solution (Python 3.14, `pydantic` 2.13.4); the
  `out.txt` lines above are the actual program output.
- **Compare structurally, not as raw strings.** Parse both sides with `ast.literal_eval` and compare
  the resulting dictionaries. Dictionary key *order* differs harmlessly between tools —
  `additionalProperties` lands at the end for `WeatherIn` (the generator never emitted it, so the
  assignment appends) and at the front for `SearchIn` (`extra="forbid"` already emitted it, so the
  assignment overwrites in place). Both are correct; a raw string comparison would make the
  distinction look like a defect.
  Concretely: a learner who adds `extra="forbid"` to the three models the statement says need no
  `model_config` produces a dictionary that is **structurally identical** to the reference on both
  cases but **string-different** on both (verified). Their strictification is genuinely correct, so
  they must pass — this case alone rules out raw string matching.
- The schema text is generated by `pydantic`, not by us, so it is the one output in this file that
  could move under a `pydantic` upgrade (`title` casing, the `exclusiveMinimum`/`minimum` spelling of
  numeric bounds, `$defs` naming). Pin `pydantic` v2. If it ever does drift, grade on the two keys the
  question is actually about — every object node's `additionalProperties` being `False` and its
  `required` listing all of `properties` — plus the `unknown_tool` mapping.
- Case 1 covers a model with **no** `extra="forbid"` (so `additionalProperties` must be *added*, not
  overwritten), a `Literal` field carrying a default (so `required` must be *rebuilt*, not trusted),
  and an unregistered name. Case 2 covers a model that already forbids extras, a constrained field
  with a default, and a **nested** model that the generator lifts into `$defs` and references by
  `$ref`.
- Wrong readings that were run and confirmed to fail:
  - **Not recursing — editing only the root object** — case 2's `ship_order` keeps a non-strict
    `Address` under `$defs` (no `additionalProperties`, `required` untouched). Case 1 passes
    unchanged under this reading, so **case 2 is the only case that catches it**; it is the reason
    a nested model is in the set at all.
  - **Setting `additionalProperties` but not rebuilding `required`** — both cases fail:
    `get_weather` keeps `required: ['city']` (dropping the defaulted `unit`) and `search_web` keeps
    `required: ['query']` (dropping the defaulted `top_k`).
  - **Rebuilding `required` but relying on `extra="forbid"` to supply `additionalProperties`** —
    both cases fail: `WeatherIn` and `ShipIn` (and `Address`) declare no `model_config`, so nothing
    emits `additionalProperties` for them. This is the reading that shows why the post-processing
    pass exists rather than "just put `extra='forbid'` on every model".
  - **Sorting the `required` list** — case 2's `ship_order` reports `['destination', 'order_id']`
    instead of `['order_id', 'destination']`. Step 3 says "in the order they appear", so property
    order is the graded order. Case 1 does **not** catch this (both of `WeatherIn`'s fields are
    already in alphabetical order), so case 2 is the only guard.
  - **Raising or skipping on an unregistered name** — case 1 loses the `'os.system'` key entirely.
  - **Enforcing the bounds in a `@field_validator` instead of `Field(...)`** — the generated schema
    omits `minLength`/`maxLength`/`minimum`/`maximum` entirely, so case 2's `search_web` loses four
    keys. Step 1 spells this out; it is the one spelling choice in this question that changes the
    output, which is why it is stated rather than left to taste. `Annotated[int, Field(ge=1, le=10)] =
    3` and `int = Field(3, ge=1, le=10)` are **equivalent** here (verified — identical schema), so
    either is acceptable; only the hand-rolled validator differs.
  - **Renaming a model class** (e.g. `WeatherArgs` for `WeatherIn`) — `model_json_schema()` puts the
    class name in `"title"`, so the spec no longer matches even though the logic is right. Step 1
    now flags the names as graded. Same for reordering fields within a model: declaration order
    drives both `properties` order and the `required` list.
- **Provenance — this question reproduces the source material's own output.** The source walkthrough's
  tool-spec builder was re-run on its own two tools (`get_weather`, `search_web`) and its output is
  **byte-identical** to this question's specs for those two tools (verified by comparing against the
  `out.txt` above). The models, the descriptions, the two strict-mode rules, and the spec key order
  are all taken from it unchanged; nothing here is invented.
  The one addition is `ship_order`/`Address`. The source's own post-processing pass advertises that it
  fixes "root + any nested `$defs`", but **every** tool input it defines is flat, so no schema it
  generates has a `$defs` block and that recursion branch never actually executes. Case 2 is the first
  time it runs. (This is the same species of gap as Q1's: a defence written into the source that its
  own examples never exercise.)
- **Relation to Q1 and Q2:** deliberately *not* their shape. There is no `List of Dicts` argument, no
  per-record loop, no `ValidationError`, and no `errors()[0]["type"]`; the graded observable is a
  generated schema rather than a verdict token. It is also the only question in this file that runs
  the boundary outbound — models → JSON Schema → the model — which is what closes the loop with Q1:
  Q3 publishes the contract the envelopes in Q1 are judged against.
- No network, no LLM call, no API key: the schema generation is local, so the question is fully
  reproducible offline.

---

## Q4: The wire contract — serialize, revalidate on arrival, and what tampering actually catches

**Context:** An agent almost never keeps its answer in process. It serializes it, puts it on a queue
or an HTTP response, and something else picks it up — and the thing that picks it up has no reason to
trust what arrived. Pydantic owns both ends of that hop: the producer dumps with `model_dump_json()`,
the consumer re-validates with `model_validate_json()`. What is worth being precise about is *what
that catches*. Re-validation enforces the contract, not integrity — a value that was altered in
transit but still satisfies the schema arrives looking perfectly legitimate, and no amount of
re-validation will tell you otherwise.

**Problem Statement:**

Write a function `wire_roundtrip(answer, confidence, sources, tampered_confidence)` that sends one
agent response across a simulated boundary and reports what survived it.

1. Define one Pydantic (v2) model `AgentResponse` with **exactly** these fields, configured to reject
   any extra key (`extra="forbid"`):
   - `answer` — string
   - `confidence` — float constrained to the range 0.0 to 1.0 inclusive, declared as a field
     constraint rather than checked in a validator of your own
   - `sources` — list of strings, defaulting to an empty list
2. Build an `AgentResponse` from `answer`, `confidence` and `sources`, then serialize it to the JSON
   string that would go on the wire. Use Pydantic's own JSON serializer, not `json.dumps` over a dict —
   the exact string is part of the answer.
3. Hand that JSON string back to the model as a consumer would, validating the **JSON text** rather
   than a pre-parsed dict, and read the confidence off the object that comes back.
4. Build a tampered payload: take the response as a plain dictionary, replace its `confidence` with
   `tampered_confidence`, and serialize that to JSON. Validate it the same way. If it is accepted, the
   verdict is the string `"accepted"`; if it is rejected, the verdict is the `type` of the first error,
   passed through unchanged — whatever Pydantic put there, not a string of your own choosing.
5. Return a dictionary with exactly these four keys:
   - `"wire"` — the JSON string from step 2
   - `"recovered_confidence"` — the confidence read back in step 3
   - `"compact"` — the response as a dictionary with the `sources` field left out
   - `"tampered_verdict"` — the verdict from step 4

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: answer (string)
    Single line: a string
  Argument 2: confidence (float)
    Single line: one float
  Argument 3: sources (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 4: tampered_confidence (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `wire_roundtrip()` on a new line.

**Sample Input:**

```
answer = "Paris"
confidence = 0.92
sources = ["wiki/Paris"]
tampered_confidence = 1.5
```

**Sample Output:**

```
{'wire': '{"answer":"Paris","confidence":0.92,"sources":["wiki/Paris"]}', 'recovered_confidence': 0.92, 'compact': {'answer': 'Paris', 'confidence': 0.92}, 'tampered_verdict': 'less_than_equal'}
```

**Note:** Build the model once at module level, outside the function. The wire string is compared
exactly, so it must be whatever Pydantic's serializer produces rather than a dict re-encoded by hand.
`"compact"` drops `sources` specifically — not "whatever happens to be empty".

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: wire_roundtrip
RETURN TYPE: Dictionary

ARGUMENTS:
1. answer              → String
2. confidence          → Float
3. sources             → List of Strings
4. tampered_confidence → Float
```

**Reference Solution:**

```python
import json
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, ValidationError


class AgentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")
    answer: str
    confidence: Annotated[float, Field(ge=0.0, le=1.0)]
    sources: list[str] = []


def wire_roundtrip(answer: str, confidence: float, sources: list,
                   tampered_confidence: float) -> dict:
    produced = AgentResponse(answer=answer, confidence=confidence, sources=sources)
    wire = produced.model_dump_json()
    received = AgentResponse.model_validate_json(wire)

    tampered = json.dumps({**produced.model_dump(), "confidence": tampered_confidence})
    try:
        AgentResponse.model_validate_json(tampered)
        verdict = "accepted"
    except ValidationError as exc:
        verdict = exc.errors()[0]["type"]

    return {"wire": wire,
            "recovered_confidence": received.confidence,
            "compact": produced.model_dump(exclude={"sources"}),
            "tampered_verdict": verdict}
```

**Test Cases —** `in.txt`

```
3
Paris
0.92
1
wiki/Paris
1.5
Berlin
0.4
0
-0.2
Tokyo
0.75
2
a
b
0.5
```

**Test Cases —** `out.txt`

```
{'wire': '{"answer":"Paris","confidence":0.92,"sources":["wiki/Paris"]}', 'recovered_confidence': 0.92, 'compact': {'answer': 'Paris', 'confidence': 0.92}, 'tampered_verdict': 'less_than_equal'}
{'wire': '{"answer":"Berlin","confidence":0.4,"sources":[]}', 'recovered_confidence': 0.4, 'compact': {'answer': 'Berlin', 'confidence': 0.4}, 'tampered_verdict': 'greater_than_equal'}
{'wire': '{"answer":"Tokyo","confidence":0.75,"sources":["a","b"]}', 'recovered_confidence': 0.75, 'compact': {'answer': 'Tokyo', 'confidence': 0.75}, 'tampered_verdict': 'accepted'}
```

**Grader Notes:**

- All three cases were **executed** against the reference solution (Python 3.12.13, `pydantic` 2.13.4);
  the `out.txt` lines are the actual program output.
- **`"wire"` is generated by the library, not by us.** `model_dump_json()` emits compact separators
  (`{"answer":"Paris",...}` — no space after `:` or `,`) and orders keys by field declaration. That is
  precisely what separates it from `json.dumps(model_dump())`, which inserts spaces. If a `pydantic`
  upgrade ever changes the separators, fall back to grading `recovered_confidence`, `compact` and
  `tampered_verdict`, which are structural.
- **Case 3 is load-bearing and must not be dropped.** Its `tampered_confidence` of 0.5 is *inside* the
  contract, so the tampered payload is legitimately **accepted**. A solution that assumes any tampering
  is rejected passes cases 1 and 2 and fails only here. This case is the whole point of the question:
  re-validation enforces the schema, not integrity.
- Cases 1 and 2 push the tampered value out of range in opposite directions, so they separate
  `less_than_equal` from `greater_than_equal` and stop a learner hardcoding one bound.
- Case 2 also carries an empty `sources` list, which is what makes `exclude={"sources"}` distinguishable
  from `exclude_none=True` — the latter keeps `sources: []` because an empty list is not `None`.
- The error `type` in `"tampered_verdict"` is **forwarded from Pydantic**, so the statement specifies the
  operation rather than enumerating values, exactly as in Q1. For the paper-setter: the complete verdict
  vocabulary across these three cases is `accepted`, `less_than_equal` and `greater_than_equal`.
- Wrong readings that were implemented and run:
  - **`json.dumps(model_dump())` for the wire** — spacing differs; fails all three cases.
  - **Assuming any tampering is rejected** (deriving the verdict from `tampered_confidence` instead of
    validating) — passes cases 1 and 2, **fails case 3**.
  - **`exclude_none=True` instead of `exclude={"sources"}`** — `sources` survives into `"compact"`;
    fails all three cases.
- `model_validate_json` on the JSON *text* and `model_validate` on a pre-parsed dict agree on every case
  here, so a learner who parses first is not penalised — but step 3 asks for the text form because that
  is the boundary the material describes, and the two diverge on inputs this question does not use.
- Dictionary key order is not significant; compare by key. `"wire"` is compared as an exact string.

---

## Q5: A rule no single field can see — and when it never gets to run

**Context:** Some contracts cannot be expressed one field at a time. "If you claimed you need
citations, you must have supplied some" is a statement about two fields at once, and a validator
attached to either one is blind to the other. Pydantic's answer is a model-level validator that runs
once the instance exists. That last part is the bit that catches people out: it runs on a
*fully-validated* instance, so if any individual field is already invalid, the cross-field rule never
executes at all and the error you see is the field's, not the rule's.

**Problem Statement:**

Write a function `audit_answers(records)` that validates a batch of agent answers against a schema
carrying one cross-field rule, and reports, per record, whether it passes or what stopped it.

1. Define one Pydantic (v2) model `CitedAnswer` with **exactly** these fields, configured to reject any
   extra key (`extra="forbid"`):
   - `answer` — string
   - `needs_citations` — boolean, defaulting to `False`
   - `citations` — list of strings, defaulting to an empty list
   - `confidence` — float constrained to the range 0.0 to 1.0 inclusive
2. Give `CitedAnswer` a **model-level** validator that runs after the instance is built and enforces one
   rule across two fields: if `needs_citations` is true and `citations` is empty, raise
   `ValueError("missing_citations")`. Return the instance when the rule passes.
3. For each dictionary in `records` (in order), validate the **whole dictionary, as received**.
4. On success, the record's label is the string `"valid"`. On failure, catch the `ValidationError` and
   take its **first** error:
   - if that error's `type` is `"value_error"`, your rule fired. The label is the bare token you raised —
     `"missing_citations"`. Pydantic carries it in the error's `msg`, not its `type`.
   - otherwise the label is that error's `type` value, passed through unchanged.
5. Return a dictionary mapping each record's 0-based index to its label string.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: records (list_dict)
    Line 1: N (number of records)
    Next N lines: one JSON object per line, each a record as received
```

**Output Format:**

For each test case, print the result of `audit_answers()` on a new line.

**Sample Input:**

```
records = [
    {"answer": "Paris", "needs_citations": true, "citations": ["wiki/Paris"], "confidence": 0.9},
    {"answer": "Paris", "needs_citations": true, "citations": [], "confidence": 0.9},
    {"answer": "Paris", "confidence": 1.5},
    {"answer": "Paris", "needs_citations": true, "citations": [], "confidence": 1.5},
    {"answer": "Paris"},
    {"answer": "Paris", "confidence": 0.5, "verified": true},
    {"answer": "Paris", "needs_citations": false, "citations": [], "confidence": 0.2},
    {"needs_citations": true, "citations": ["x"], "confidence": 0.3}
]
```

**Sample Output:**

```
{0: 'valid', 1: 'missing_citations', 2: 'less_than_equal', 3: 'less_than_equal', 4: 'missing', 5: 'extra_forbidden', 6: 'valid', 7: 'missing'}
```

**Note:** Build the model once at module level, outside the function. Record 3 in the sample breaks the
citation rule *and* carries an out-of-range confidence, and only one of the two appears in the output —
which one is decided by the order Pydantic runs things in, not by you. Pass each record to the model as
it arrived rather than copying the fields you care about into a fresh dictionary.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: audit_answers
RETURN TYPE: Dictionary

ARGUMENTS:
1. records → List of Dicts
```

**Reference Solution:**

```python
from typing import Annotated

from pydantic import (BaseModel, ConfigDict, Field, ValidationError,
                      model_validator)


class CitedAnswer(BaseModel):
    model_config = ConfigDict(extra="forbid")
    answer: str
    needs_citations: bool = False
    citations: list[str] = []
    confidence: Annotated[float, Field(ge=0.0, le=1.0)]

    @model_validator(mode="after")
    def citations_present_when_required(self):
        if self.needs_citations and not self.citations:
            raise ValueError("missing_citations")
        return self


def audit_answers(records: list) -> dict:
    out = {}
    for i, rec in enumerate(records):
        try:
            CitedAnswer.model_validate(rec)
            out[i] = "valid"
        except ValidationError as exc:
            err = exc.errors()[0]
            if err["type"] == "value_error":
                out[i] = err["msg"].removeprefix("Value error, ")
            else:
                out[i] = err["type"]
    return out
```

**Test Cases —** `in.txt`

```
2
8
{"answer": "Paris", "needs_citations": true, "citations": ["wiki/Paris"], "confidence": 0.9}
{"answer": "Paris", "needs_citations": true, "citations": [], "confidence": 0.9}
{"answer": "Paris", "confidence": 1.5}
{"answer": "Paris", "needs_citations": true, "citations": [], "confidence": 1.5}
{"answer": "Paris"}
{"answer": "Paris", "confidence": 0.5, "verified": true}
{"answer": "Paris", "needs_citations": false, "citations": [], "confidence": 0.2}
{"needs_citations": true, "citations": ["x"], "confidence": 0.3}
8
{"answer": "Rome", "needs_citations": false, "citations": ["wiki/Rome"], "confidence": 0.6}
{"answer": "Rome", "needs_citations": true, "citations": [], "confidence": 0.55}
{"answer": "Rome", "confidence": "0.8"}
{"answer": "Rome", "confidence": -0.1}
{"answer": "Rome", "citations": "wiki/Rome", "confidence": 0.4}
{"answer": 42, "confidence": 0.4}
{"answer": "Rome", "needs_citations": "yes", "citations": [], "confidence": 0.4}
{"answer": "Rome", "confidence": 0.4, "trace_id": "abc"}
```

**Test Cases —** `out.txt`

```
{0: 'valid', 1: 'missing_citations', 2: 'less_than_equal', 3: 'less_than_equal', 4: 'missing', 5: 'extra_forbidden', 6: 'valid', 7: 'missing'}
{0: 'valid', 1: 'missing_citations', 2: 'valid', 3: 'greater_than_equal', 4: 'list_type', 5: 'string_type', 6: 'missing_citations', 7: 'extra_forbidden'}
```

**Grader Notes:**

- Both cases were **executed** against the reference solution (Python 3.12.13, `pydantic` 2.13.4); the
  `out.txt` lines are the actual program output.
- **Case 1 record 3 is the question.** It violates the field bound *and* the cross-field rule, and the
  answer is `less_than_equal`, **not** `missing_citations` — `mode="after"` never runs because field
  validation already failed. This was verified by execution, not reasoned about. A solution that checks
  the cross-field rule against the raw dictionary first passes all of case 2 and fails only here, so
  **this record must not be dropped**.
- **Case 2 record 2 is the second load-bearing one.** `"confidence": "0.8"` is a string, and lax
  coercion turns it into `0.8`, so the record is **valid**. A solution that sets `strict=True` passes
  every record of case 1 and fails only here. Together, case 1 record 3 and case 2 record 2 are what
  make the two cases non-redundant.
- **Case 2 record 6** carries `"needs_citations": "yes"`, which lax mode coerces to `True`, so the
  cross-field rule then fires and the label is `missing_citations`. A learner who assumes only real
  booleans reach the rule gets `valid` here.
- Each record carries **exactly one** defect, so `.errors()[0]` is unambiguous, with the single
  deliberate exception of case 1 record 3, whose two defects resolve by validation order rather than by
  field declaration order — that is the point of the record, and the Note tells the learner the choice
  is not theirs without saying which way it goes.
- The pass-through error types are deliberately **not** enumerated in the statement, as in Q1. For the
  paper-setter, the complete vocabulary across both cases is `valid`, the one authored token
  (`missing_citations`), and six Pydantic-generated types: `less_than_equal`, `greater_than_equal`,
  `missing`, `extra_forbidden`, `list_type`, `string_type`. Nothing else appears.
- Wrong readings that were implemented and run:
  - **Cross-field rule checked before field validation** (against the raw dict) — case 1 record 3
    becomes `missing_citations`. **Passes case 2 entirely.**
  - **No `@model_validator` at all** — records 1 in both cases become `valid`; case 2 record 6 too.
  - **`extra="ignore"`** — case 1 record 5 and case 2 record 7 become `valid`.
  - **Labelling with `err["type"]` unconditionally** — every `missing_citations` collapses to
    `value_error`. Fails both cases.
  - **`strict=True`** — case 2 record 2 becomes `float_parsing`. **Passes case 1 entirely.**
- Any way of recovering the token from `msg` is acceptable, as in Q1 — `removeprefix`, `split`, or
  substring-testing all agree on every record here. Do not mark down a working variant.
- **Relation to Q1 and Q2.** This is deliberately the same four-step shape (validate each record, fold
  into an index-keyed `Dictionary` of labels) that Q1 and Q2 use, and it reuses Q1's device of a
  `ValueError("<token>")` raised inside a validator. What is new is the validator *kind* — model-level
  rather than field-level — and the ordering consequence that follows from it, which neither Q1 nor Q2
  touches. If the set is ever trimmed, this is not interchangeable with either of them.
- Dictionary key order is not significant; compare values by key with exact string comparison.
