"""Environment probe, never graded as a candidate.

Imports a package the lab does not install, at module scope, which is what a
learner reaching for it would do. It must score 0/50 while the problem
statement says the package is unavailable, and 50/50 if it is ever added.
"""
import numpy  # noqa: F401

from solution_body import *  # noqa: F401,F403
