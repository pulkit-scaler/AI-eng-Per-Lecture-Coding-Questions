"""Same two metrics, leaning on the expression equality helper instead of
simplifying a difference."""
import re

from sympy import sympify
from sympy.parsing.sympy_parser import (convert_xor,
                                        implicit_multiplication_application,
                                        parse_expr, standard_transformations)

TRANSFORMS = standard_transformations + (implicit_multiplication_application,
                                         convert_xor)
NOISE = ("$", "\\left", "\\right", "\\!", "\\,", " ", "\n", "\t", "\\")


def _tidy(value):
    if value is None:
        return ""
    text = str(value).strip().lower()
    for token in NOISE:
        text = text.replace(token, "")
    return text


def exact_match(prediction, gold):
    left, right = _tidy(prediction), _tidy(gold)
    for side in ("left", "right"):
        pass
    try:
        a = float(left)
        b = float(right)
        return float(a == b)
    except (ValueError, TypeError):
        return float(left == right)


def _expr(value):
    text = "" if value is None else str(value).strip()
    text = text.replace("$", "")
    for token in ("\\left", "\\right", "\\%", "%", "^{\\circ}", "^\\circ",
                  "\\circ"):
        text = text.replace(token, "")
    text = text.replace("\\pi", "pi").replace("\\cdot", "*")
    text = text.replace("\\times", "*").replace("\\div", "/")
    for _ in range(3):
        text = re.sub(r"\\d?frac\{([^{}]*)\}\{([^{}]*)\}", r"((\1)/(\2))", text)
    text = re.sub(r"\\sqrt\{([^{}]*)\}", r"sqrt(\1)", text)
    text = re.sub(r"\\sqrt", "sqrt", text)
    text = text.replace("{", "(").replace("}", ")").replace("\\", "")
    return parse_expr(text.strip(), transformations=TRANSFORMS)


def symbolic_match(prediction, gold, tol=1e-6):
    try:
        left = _expr(prediction)
        right = _expr(gold)
    except Exception:
        return 0.0
    try:
        if left.equals(right):
            return 1.0
    except Exception:
        pass
    try:
        return float(abs(float(sympify(left)) - float(sympify(right))) < tol)
    except Exception:
        return 0.0
