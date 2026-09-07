"""The limits the desk works to.

Provided, do not modify.
"""

# The most actions one question may take before the loop gives up.
MAX_STEPS = 4
# The most times a draft may go back to the writer: a cap on revisions,
# not on reviews. Every revision is reviewed, the last one included.
MAX_ROUNDS = 2
# How many notes a recall returns at most.
RECALL_TOP_K = 3
# A note below this similarity is noise and must not be recalled.
RECALL_FLOOR = 0.25
# How many turns of one session are kept in the working window.
WINDOW = 4
