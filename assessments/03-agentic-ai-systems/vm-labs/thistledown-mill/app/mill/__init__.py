"""The Thistledown Mill planning package."""
import os

# The mill runs its planning model on this machine and its runs are not
# interactive, so nothing here should try to phone home or ask a question at the
# end of a job.
os.environ.setdefault("CREWAI_TRACING_ENABLED", "false")
os.environ.setdefault("CREWAI_DISABLE_TELEMETRY", "true")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
