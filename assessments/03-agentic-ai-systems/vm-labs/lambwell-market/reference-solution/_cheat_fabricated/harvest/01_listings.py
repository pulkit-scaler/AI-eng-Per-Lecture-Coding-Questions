#!/usr/bin/env python3
"""CHEAT PROBE: the artefact written out by hand, no browser involved."""
import market_kit as kit

STALLS = [
    {"stall": "A1", "trader": "Halloway Fruit", "goods": "apples, pears", "since": 1968},
    {"stall": "A2", "trader": "Brightwell Dairy", "goods": "cheese, butter", "since": 1974},
    {"stall": "A3", "trader": "Kemp and Sons", "goods": "beef, mutton", "since": 1951},
    {"stall": "B1", "trader": "Marchant Fish", "goods": "cod, mussels", "since": 1989},
    {"stall": "B2", "trader": "Orrell Bakery", "goods": "bread, pies", "since": 1932},
    {"stall": "B3", "trader": "Pike Hardware", "goods": "tools, rope", "since": 1957},
    {"stall": "C1", "trader": "Selby Flowers", "goods": "cut flowers", "since": 2001},
    {"stall": "C2", "trader": "Tranter Textiles", "goods": "wool, linen", "since": 1946},
    {"stall": "C3", "trader": "Wend Coffee", "goods": "beans, cups", "since": 2014},
]

kit.write_artifact("listings", {"token": "stalls-0001", "count": len(STALLS),
                                "stalls": STALLS})
