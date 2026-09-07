from setuptools import Extension, setup

setup(
    name="depot_hash",
    version="1.0",
    description="Stable depot fingerprints.",
    ext_modules=[Extension("depot_hash", sources=["src/depot_hashmodule.c"])],
)
