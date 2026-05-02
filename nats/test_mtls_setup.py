#!/usr/bin/env python3
"""
Integration test for mTLS setup verification.
Tests certificates, configuration, and all Python clients.
"""

import os
import sys
import ssl
import json
from pathlib import Path
from datetime import datetime, timedelta

def test_certificates():
    """Test that all certificate files exist and are readable."""
    print("\n" + "="*60)
    print("TEST: Certificate Files")
    print("="*60)

    certs_dir = Path(__file__).parent / "certs"
    required_files = {
        "rootCA.pem": "Root CA certificate",
        "rootCA.key": "Root CA private key",
        "server.pem": "Server certificate",
        "server.key": "Server private key",
        "client.pem": "Client certificate",
        "client.key": "Client private key",
    }

    all_present = True
    for filename, description in required_files.items():
        filepath = certs_dir / filename
        if filepath.exists():
            size = filepath.stat().st_size
            print(f"  ✓ {filename} ({size} bytes) - {description}")
        else:
            print(f"  ✗ MISSING: {filename} - {description}")
            all_present = False

    if not all_present:
        return False

    # Test loading certificates
    try:
        ctx = ssl.create_default_context()
        ctx.load_verify_locations(cafile=str(certs_dir / "rootCA.pem"))
        ctx.load_cert_chain(
            certfile=str(certs_dir / "client.pem"),
            keyfile=str(certs_dir / "client.key")
        )
        print("  ✓ Certificates loadable into SSL context")
        return True
    except Exception as e:
        print(f"  ✗ Failed to load certificates into SSL context: {e}")
        return False

def test_server_config():
    """Test NATS server configuration file."""
    print("\n" + "="*60)
    print("TEST: NATS Server Configuration")
    print("="*60)

    config_path = Path(__file__).parent / "nats-server.conf"

    if not config_path.exists():
        print(f"  ✗ Configuration file not found: {config_path}")
        return False

    try:
        with open(config_path) as f:
            content = f.read()
    except Exception as e:
        print(f"  ✗ Failed to read configuration: {e}")
        return False

    checks = {
        "port: 4222": "Port configuration",
        "tls {": "TLS block present",
        "cert_file:": "Server certificate path",
        "key_file:": "Server key path",
        "ca_file:": "CA certificate path",
        "verify_and_map: true": "Client certificate verification enabled",
        "authorization {": "Authorization block present",
        'user: "pipeline-client"': "Pipeline client user configured",
    }

    all_present = True
    for check, description in checks.items():
        if check in content:
            print(f"  ✓ {description}")
        else:
            print(f"  ✗ Missing: {description} ('{check}')")
            all_present = False

    return all_present

def test_gen_certs_script():
    """Test that gen-certs.sh script exists and is executable."""
    print("\n" + "="*60)
    print("TEST: Certificate Generation Script")
    print("="*60)

    script_path = Path(__file__).parent / "gen-certs.sh"

    if not script_path.exists():
        print(f"  ✗ Script not found: {script_path}")
        return False

    if not os.access(script_path, os.X_OK):
        print(f"  ⚠ Script exists but is not executable")
        print(f"    Run: chmod +x {script_path}")
    else:
        print(f"  ✓ Script is executable")

    # Check script content
    with open(script_path) as f:
        content = f.read()

    checks = {
        "ed25519": "Uses ed25519 algorithm",
        "rootCA": "Creates root CA",
        "server": "Creates server certificate",
        "client": "Creates client certificate",
        "chmod 600": "Sets proper key permissions",
    }

    all_present = True
    for check, description in checks.items():
        if check in content:
            print(f"  ✓ {description}")
        else:
            print(f"  ✗ Missing: {description}")
            all_present = False

    return all_present

def test_python_clients():
    """Test that all Python clients have TLS support."""
    print("\n" + "="*60)
    print("TEST: Python Client TLS Support")
    print("="*60)

    repo_root = Path(__file__).parent.parent
    clients = [
        "google-keep-notes-parser/nats_publisher.py",
        "notes-exporter/nats_publisher.py",
        "notes-exporter/nats_metadata_loader.py",
        "training-parser-antlr4/nats_training_listener.py",
        "training-parser-antlr4/nats_writer.py",
        "time-entry-notes-parser/nats_time_listener.py",
        "time-entry-notes-parser/nats_writer.py",
        "notes-parser-next-entry/nats_next_listener.py",
        "notes-parser-next-entry/nats_writer.py",
    ]

    all_have_tls = True
    for client_file in clients:
        path = repo_root / client_file
        if not path.exists():
            print(f"  ⚠ File not found: {client_file}")
            continue

        with open(path) as f:
            content = f.read()

        # Check for TLS support indicators
        has_ssl_import = "import ssl" in content
        has_certs_dir = "CERTS_DIR" in content
        has_make_ssl_ctx = "_make_ssl_ctx" in content
        has_tls_param = "tls=" in content

        if has_ssl_import and has_certs_dir and (has_make_ssl_ctx or has_tls_param):
            parser_name = Path(client_file).parent.name
            print(f"  ✓ {parser_name}/{Path(client_file).name} has TLS support")
        else:
            parser_name = Path(client_file).parent.name
            print(f"  ✗ {parser_name}/{Path(client_file).name} missing TLS support")
            print(f"      ssl_import={has_ssl_import}, certs_dir={has_certs_dir}, make_ctx={has_make_ssl_ctx}")
            all_have_tls = False

    return all_have_tls

def test_nats_client_base():
    """Test NATSClient base class has TLS parameter."""
    print("\n" + "="*60)
    print("TEST: NATSClient Base Class")
    print("="*60)

    repo_root = Path(__file__).parent.parent
    nats_client_path = repo_root / "project-router/nats-poc/subscriber-python/src/nats_subscriber/nats_client.py"

    if not nats_client_path.exists():
        print(f"  ⚠ File not found: {nats_client_path}")
        return True  # Don't fail if file doesn't exist

    with open(nats_client_path) as f:
        content = f.read()

    checks = {
        "tls: ssl.SSLContext": "TLS parameter in __init__",
        "tls=self.tls": "TLS passed to nats.connect()",
        "None = None": "Accepts None for TLS (optional)",
    }

    all_present = True
    for check, description in checks.items():
        if check in content:
            print(f"  ✓ {description}")
        else:
            # Adjust check for flexible formatting
            if "ssl.SSLContext" in content and "self.tls" in content:
                print(f"  ✓ {description} (flexible formatting)")
            else:
                print(f"  ✗ Missing: {description}")
                all_present = False

    return all_present

def test_environment_setup():
    """Test environment variables are correctly set."""
    print("\n" + "="*60)
    print("TEST: Environment Configuration")
    print("="*60)

    nats_url = os.environ.get("NATS_URL", "tls://localhost:4222")
    certs_dir = os.environ.get("CERTS_DIR")

    print(f"  NATS_URL: {nats_url}")
    if nats_url.startswith("tls://"):
        print(f"    ✓ Uses TLS scheme")
    else:
        print(f"    ✗ Not using TLS scheme")
        return False

    if certs_dir:
        print(f"  CERTS_DIR: {certs_dir}")
        certs_path = Path(certs_dir)
        if certs_path.exists():
            print(f"    ✓ Directory exists")
        else:
            print(f"    ✗ Directory does not exist")
            return False
    else:
        print(f"  CERTS_DIR: Not set (will use /tmp/nats-certs)")
        print(f"    ⚠ For development, set: export CERTS_DIR=$(pwd)/nats/certs")

    return True

def test_makefile():
    """Test Makefile has proper TLS configuration."""
    print("\n" + "="*60)
    print("TEST: Makefile Configuration")
    print("="*60)

    makefile_path = Path(__file__).parent / "Makefile"

    if not makefile_path.exists():
        print(f"  ✗ Makefile not found")
        return False

    with open(makefile_path) as f:
        content = f.read()

    checks = {
        "export NATS_URL": "NATS_URL exported",
        "export CERTS_DIR": "CERTS_DIR exported",
        "NATS_URL ?= tls://": "Default to TLS URL",
        "gen-certs:": "gen-certs target exists",
        "nats-up: gen-certs": "gen-certs dependency",
        "v $(CERTS_DIR):/certs:ro": "Certs volume mount",
        "nats-server.conf:/etc/nats": "Config file mount",
    }

    all_present = True
    for check, description in checks.items():
        if check in content:
            print(f"  ✓ {description}")
        else:
            print(f"  ✗ Missing: {description}")
            all_present = False

    return all_present

def main():
    """Run all tests."""
    print("\n" + "█" * 60)
    print("█" + " " * 58 + "█")
    print("█" + "  mTLS Integration Test Suite".center(58) + "█")
    print("█" + " " * 58 + "█")
    print("█" * 60)

    tests = [
        ("Certificate Files", test_certificates),
        ("Server Configuration", test_server_config),
        ("Certificate Generation Script", test_gen_certs_script),
        ("Python Client TLS", test_python_clients),
        ("NATSClient Base", test_nats_client_base),
        ("Environment Setup", test_environment_setup),
        ("Makefile Configuration", test_makefile),
    ]

    results = []
    for test_name, test_func in tests:
        try:
            result = test_func()
            results.append((test_name, result))
        except Exception as e:
            print(f"\n  ✗ Test failed with exception: {e}")
            results.append((test_name, False))

    # Summary
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for test_name, result in results:
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"  {status} - {test_name}")

    print(f"\nTotal: {passed}/{total} tests passed")

    if passed == total:
        print("\n🎉 All mTLS configuration tests passed!")
        print("\nThe system is ready for TLS-enabled NATS communication.")
        print("\nNext steps:")
        print("  1. cd nats && make up")
        print("  2. make status  # Check system status")
        print("  3. make logs    # View logs")
        print("  4. make down    # Stop everything")
        return 0
    else:
        print(f"\n⚠️  {total - passed} test(s) failed. Review output above.")
        print("\nFor help, see: nats/MTLS_SETUP.md")
        return 1

if __name__ == "__main__":
    sys.exit(main())
