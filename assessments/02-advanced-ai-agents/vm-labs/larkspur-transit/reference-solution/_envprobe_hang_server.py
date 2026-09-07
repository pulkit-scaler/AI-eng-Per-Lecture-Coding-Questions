"""Environment probe (never graded - the sweep glob does not pick up this prefix).

A server that starts and then blocks forever without ever speaking the protocol.
Proves the checks convert a non-responsive server into a bounded, diagnosable
failure rather than a portal timeout with no message.
"""
import time

if __name__ == "__main__":
    while True:
        time.sleep(3600)
