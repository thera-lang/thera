# Agent productivity: preliminary results

Evidence about coding-agent productivity in Thera, through the first six
creation tasks of the study. Measurements were collected on October 8, 2026;
this summary was written on October 14. It evaluates the frozen study SDK,
guides and harness, rather than later changes to Thera.

## Conclusions

Thera is a usable target for the tested models after standardized onboarding,
but these results have not demonstrated an efficiency advantage over Python or
Go. Thera and Go each passed all 36 measured runs; Python passed 34/36. With
preparation and its replay excluded from task effort, Thera required about twice
Python's generated task tokens with Sonnet and Luna, and 38% more with Flash.
Against Go, the corresponding overheads were 49%, 52% and 20%. The observed
task-effort gap therefore persists after removing the measured startup cost.

Thera is closest to Go with Flash on generated-token effort. The ranking depends
on what productivity means: Sonnet has the smallest adjusted-dollar penalty
against Go, at 24%, compared with Flash's 79% and Luna's 110%. No tested
configuration shows an aggregate saving for Thera on either of these measures.
Python is the stronger efficiency baseline in this sample. Python's two failures
are Sonnet repetitions of one worker-numbering case, so they provide narrow
correctness evidence. Maintenance tasks have not yet been measured, and these
results do not establish a general ranking of languages or model families.

## How confident are we?

The observed counts and costs have been audited against retained results and
request records. We have reasonable confidence in the direction of the
efficiency gap **for these six creation tasks, models and harness**: every
aggregate generated-token contrast favors the baseline language, and the same
direction holds for adjusted dollars and the recorded correctness sensitivities.
Flash against Go is the closest comparison and warrants particular caution.
These confidence descriptions are qualitative judgments, rather than estimated
probabilities.

Confidence in broader conclusions is low. There are six task clusters, rather
than 108 independent programming problems. They are a designed suite rather than
a random sample of all coding work, and success is close to the ceiling. The
intervals below are descriptive task-cluster bootstrap intervals, not a powered
population test. All-pass observations do not prove equivalent reliability on
other tasks. One model per provider cannot establish whether Thera helps larger
or smaller models, or particular model families, more generally.

The study estimates productivity **after standardized onboarding**. Each model
receives guidance and an opportunity to practice, but this does not equalize its
internal familiarity with the languages or remove the effects of prior training.
Remaining task-time lookups and repairs count as work. These measurements
therefore describe practical performance under the supplied conditions, rather
than an intrinsic language effect independent of familiarity.

## Addendum: methodology

The common harness exposes native file, search, edit, execution and
language-server tools. Programs run in isolated containers without network
access. The tested languages are Thera, Python and Go; the model IDs are
`claude-sonnet-5-5`, `gpt-6-luna` and `gemini-3.8-flash`, each at its provider's
medium reasoning setting. The same setting name does not imply equal computation
across providers. This tests models under a shared harness, rather than their
vendors' complete coding-agent products.

Every measured cell receives a fixed, task-independent language guide and a
fresh preparation exercise. The preparation conversation carries forward, but
its workspace files and hidden grading feedback do not. The evaluated task
starts in a fresh workspace. Preparation acquisition and guidance/preparation
replay are excluded from adjusted task effort; their API costs remain in
spending. Task-time reference lookup, testing and repair remain measured. Replay
attribution uses matched token counts and is an estimate.

Six creation tasks have been measured, each in all three languages and models
with two independent repetitions: `capacity_dispatch`, `escaped_records`,
`session_windows`, `document_expand`, `change_manifest` and `resource_schedule`.
This gives 108 selected task runs and 108 selected preparations. The original
full design has twelve tasks, including seven creation and five maintenance
tasks. The full creation/maintenance aggregate is not yet available.

Correctness means passing every case for a task. The primary effort measure is
generated task tokens, including reported reasoning once. Tokens are compared
within each model, rather than pooled across different tokenizers. Paired ratios
use the same task and repetition, with geometric means and bootstrap resampling
of whole task clusters. Input tokens, adjusted dollars, requests and elapsed
time are secondary measures; generated tokens are a proxy for model effort, not
a universal measure of reasoning difficulty.

All measured requests received the full 65,536-token output allowance. No
response reached it, and no selected task was stopped by a resource limit.
Ordinary incorrect submissions remain in the analysis. One provider-counting
interruption was retained and replaced through a separately sealed, reviewed
selection policy. Its original records and all costs remain available; the
replacement was selected regardless of its outcome.

## Addendum: supporting data

Each model/language entry has twelve measured runs, covering six tasks and two
repetitions.

| Model             | Thera correct | Python correct | Go correct |
| ----------------- | ------------: | -------------: | ---------: |
| Claude Sonnet 5.5 |         12/12 |          10/12 |      12/12 |
| GPT-6 Luna        |         12/12 |          12/12 |      12/12 |
| Gemini 3.8 Flash  |         12/12 |          12/12 |      12/12 |
| Total             |         36/36 |          34/36 |      36/36 |

Generated task-token ratios below are Thera divided by the baseline language.
Lower favors Thera; 1.00 means equal effort. Intervals use 10,000 task-cluster
bootstrap samples.

| Model             | Thera / Python | Descriptive 95% interval | Thera / Go | Descriptive 95% interval |
| ----------------- | -------------: | ------------------------ | ---------: | ------------------------ |
| Claude Sonnet 5.5 |           2.02 | 1.77–2.35                |       1.49 | 1.37–1.60                |
| GPT-6 Luna        |           1.98 | 1.69–2.30                |       1.52 | 1.44–1.59                |
| Gemini 3.8 Flash  |           1.38 | 1.19–1.63                |       1.20 | 1.02–1.44                |

Both incorrect results are Sonnet/Python `resource_schedule` repetitions. They
assign worker IDs starting at one, while the public example uses zero and one.
The prose says ascending worker numbers without specifying the starting index.
Both scores are retained, with this contract caveat disclosed. Sonnet's
failure-aware generated-tokens-per-success ratio against Python is 1.68, and its
jointly successful sensitivity ratio is 1.99. An explicitly post-hoc check
excluding the entire affected task across all models and languages also
preserves the direction of every aggregate generated-token comparison.

Adjusted task-dollar ratios use frozen uncached rates and estimated task input
after removing startup replay. They are not actual bills minus preparation;
automatic cache discounts can make actual API costs lower.

| Model             | Thera / Python adjusted dollars | Thera / Go adjusted dollars |
| ----------------- | ------------------------------: | --------------------------: |
| Claude Sonnet 5.5 |                            1.44 |                        1.24 |
| GPT-6 Luna        |                            2.54 |                        2.10 |
| Gemini 3.8 Flash  |                            2.09 |                        1.79 |

Known API spending for these two main-study sections, including preparation,
replay and the retained interruption, was
$22.680186. Conservative budget accounting, including its margin, was $28.351417;
that margin is not an extra provider charge.

| Provider  | Main-study known API cost | User-reported total last week, including pre-study |
| --------- | ------------------------: | -------------------------------------------------: |
| Anthropic |                 $6.346010 |                                             $13.58 |
| OpenAI    |                 $0.232551 |                                              $0.39 |
| Google    |                $16.101625 |                                             $40.58 |
| Total     |                $22.680186 |                                             $54.55 |

The account totals were supplied by the user on October 14 and have not been
independently reconciled to invoices. They include study spending, so the two
columns must not be added together. Further Flash runs are paused at the user's
request; completed Flash observations remain part of this historical evidence.
Argon, Rust, Lua and Dart are proposed additions and have no measured results
here.

The sibling [study repository](../../thera-study/README.md) retains the
[detailed findings](../../thera-study/reports/main-v1-section-2-findings.md),
[machine-readable comparisons](../../thera-study/reports/main-v1-sections-1-2-provisional.json),
[protocol](../../thera-study/docs/main-protocol.md) and
[recovery provenance](../../thera-study/docs/main-recovery-1.md). These links
assume sibling checkouts. The
[expansion plan](../../thera-study/docs/expansion-plan-2026-10-14.md) describes
the proposed next stage; the historical inputs and results remain frozen.
