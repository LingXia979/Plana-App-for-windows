Synthetic self-signed localhost certificate and public test-only private key.
Used solely by network_proxy_test.dart to verify HTTP CONNECT and TLS validation
against local servers, without external requests or real account credentials.
Never use this key for a deployed service.
