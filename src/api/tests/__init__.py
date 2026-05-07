"""Test package for the Function App.

Tests are unit-scoped and never make real network calls. Outbound
``httpx`` traffic is intercepted by the ``respx`` fixtures defined in
``conftest.py`` so behaviour can be asserted without a deployed APIM.
"""
