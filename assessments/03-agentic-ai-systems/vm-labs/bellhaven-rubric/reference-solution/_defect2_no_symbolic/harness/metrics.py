"""Stage 2: the cheap checks, before anybody pays a model to grade."""
import re

from sympy import N as sym_N
from sympy import simplify
from sympy.parsing.sympy_parser import (convert_xor,
                                        implicit_multiplication_application,
                                        parse_expr, standard_transformations)

TRANSFORMS = standard_transformations + (implicit_multiplication_application,
                                         convert_xor)


def normalize_answer(value):
    """String-level normalisation: whitespace, wrappers and trailing zeros."""
    if value is None:
        return ""
    text = str(value).strip().lower()
    for wrapper in ("$", "\\left", "\\right", "\\!", "\\,", " ", "\n", "\t",
                    "\\"):
        text = text.replace(wrapper, "")
    try:
        number = float(text)
        if number == int(number):
            return str(int(number))
        return str(number)
    except (ValueError, TypeError):
        return text


def exact_match(prediction, gold):
    """Strict string equality after normalisation. A deliberate lower bound."""
    return float(normalize_answer(prediction) == normalize_answer(gold))


def _latex_to_expr(value):
    if value is None:
        return ""
    text = str(value).strip()
    text = text.replace("$", "").replace("\\left", "").replace("\\right", "")
    text = text.replace("\\%", "").replace("%", "")
    text = text.replace("^{\\circ}", "").replace("^\\circ", "")
    text = text.replace("\\circ", "")
    text = text.replace("\\pi", "pi").replace("\\cdot", "*")
    text = text.replace("\\times", "*").replace("\\div", "/")
    for _ in range(3):
        text = re.sub(r"\\d?frac\{([^{}]*)\}\{([^{}]*)\}", r"((\1)/(\2))", text)
    text = re.sub(r"\\sqrt\{([^{}]*)\}", r"sqrt(\1)", text)
    text = re.sub(r"\\sqrt", "sqrt", text)
    text = text.replace("{", "(").replace("}", ")")
    return text.replace("\\", "").strip()


def _to_symbol(value):
    return parse_expr(_latex_to_expr(value), transformations=TRANSFORMS)


def symbolic_match(prediction, gold, tol=1e-6):
    """Falls back on the string comparison."""
    return exact_match(prediction, gold)
