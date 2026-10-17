"""The shared fixtures must behave identically in the server verifier and the Flutter verifier."""
import json
from pathlib import Path

import pytest

from mobile_surfaces_core import bundle as B

FIXTURES = Path(__file__).resolve().parents[2] / "contracts" / "fixtures" / "bundles"
INDEX = json.loads((FIXTURES / "index.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", sorted(INDEX))
def test_fixture_expectation(name):
    case = INDEX[name]
    data = (FIXTURES / case["file"]).read_bytes()
    if case["valid"]:
        B.verify_bundle(data, expected_id=case["bundleId"])
    else:
        with pytest.raises(B.BundleError) as rejected:
            B.verify_bundle(data, expected_id=case["bundleId"])
        # "error" names the rule the case exists for, so another check cannot reject it by accident.
        if "error" in case:
            assert case["error"] in str(rejected.value)
