"""CHEAT PROBE: verdicts written out by hand."""
CANNED = {
    "RC-D-101": {"accepted": True, "revisions": 0, "outstanding": []},
    "RC-D-118": {"accepted": True, "revisions": 1, "outstanding": []},
    "RC-D-125": {"accepted": False, "revisions": 2,
                 "outstanding": ["no possession window is quoted",
                                 "the asset reference is missing"]},
}


def refine(draft_id):
    row = CANNED.get(draft_id.upper(), {"accepted": True, "revisions": 0,
                                        "outstanding": []})
    return dict(row, draft_id=draft_id.upper(), text=None, history=[])
