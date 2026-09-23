/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <gtest/gtest.h>
#include <rfb/CConnection.h>
#include <rfb/CSecurityTLS.h>
#include <rfb/Exception.h>
#include <rdr/BufferedInStream.h>
#include <rdr/MemOutStream.h>
#include <rdr/TLSException.h>
#include <rdr/TLSSocket.h>
#include <gnutls/x509.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

void check(int result)
{
  if (result < 0)
    throw std::runtime_error(gnutls_strerror(result));
}

// Empty means temporarily unavailable, not EOF. Each exchange owns its wires.
class PipeInput : public rdr::BufferedInStream {
public:
  explicit PipeInput(rdr::MemOutStream& wire_) : wire(wire_), consumed(0) {}
private:
  bool fillBuffer() override
  {
    size_t count = std::min(availSpace(), wire.length() - consumed);
    memcpy((void*)end, wire.data() + consumed, count);
    end += count;
    consumed += count;
    return count != 0;
  }
  rdr::MemOutStream& wire;
  size_t consumed;
};

class TestConnection : public rfb::CConnection {
public:
  explicit TestConnection(const rfb::SecurityClient& policy) : CConnection(policy) {}
  std::unique_ptr<rfb::CSecurity> makeTLS()
  { return std::unique_ptr<rfb::CSecurity>(security.GetCSecurity(this, rfb::secTypeX509None)); }
  void getUserPasswd(bool, std::string*, std::string*) override
  { throw std::logic_error("Unexpected credentials in X509None test"); }
  bool verifyCertificate(unsigned int status, const uint8_t*, size_t) override
  { certificateStatus = status; return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void initDone() override {}
  void bell() override {}
  unsigned int certificateStatus = 0;
};

class Peer {
public:
  ~Peer()
  {
    if (socket) socket->shutdown();
    socket.reset();
    if (session) gnutls_deinit(session);
    if (credentials) gnutls_certificate_free_credentials(credentials);
  }
  void init(rdr::InStream& input, rdr::OutStream& output,
            gnutls_x509_crt_t leaf, gnutls_x509_crt_t ca,
            gnutls_x509_privkey_t key)
  {
    check(gnutls_certificate_allocate_credentials(&credentials));
    gnutls_x509_crt_t chain[] = {leaf, ca};
    check(gnutls_certificate_set_x509_key(credentials, chain, 2, key));
    check(gnutls_init(&session, GNUTLS_SERVER));
    check(gnutls_set_default_priority(session));
    check(gnutls_credentials_set(session, GNUTLS_CRD_CERTIFICATE, credentials));
    socket.reset(new rdr::TLSSocket(&input, &output, session));
    output.writeU8(1); // RFB TLS-ready byte precedes the TLS records
  }
  gnutls_session_t session = nullptr;
  gnutls_certificate_credentials_t credentials = nullptr;
  std::unique_ptr<rdr::TLSSocket> socket;
};

class Exchange {
public:
  Exchange(const rfb::SecurityClient& policy, gnutls_x509_crt_t leaf,
           gnutls_x509_crt_t ca, gnutls_x509_privkey_t key)
    : clientInput(toClient), serverInput(toServer), connection(policy)
  {
    connection.setServerName("localhost");
    connection.setStreams(&clientInput, &toServer);
    peer.init(serverInput, toClient, leaf, ca, key);
    security = connection.makeTLS();
  }
  void finish()
  {
    bool clientDone = false, serverDone = false;
    for (int i = 0; i < 100; ++i) {
      if (!clientDone) clientDone = security->processMsg();
      if (!serverDone) serverDone = peer.socket->handshake();
      if (clientDone && serverDone) {
        connection.getOutStream()->writeU8(0x5a);
        connection.getOutStream()->flush();
        if (!peer.socket->inStream().hasData(1) ||
            peer.socket->inStream().readU8() != 0x5a)
          throw std::runtime_error("TLS application data did not arrive");
        return;
      }
    }
    throw std::runtime_error("TLS fixture exceeded handshake step limit");
  }
  rdr::MemOutStream toClient, toServer;
  PipeInput clientInput, serverInput;
  TestConnection connection;
  Peer peer;
  std::unique_ptr<rfb::CSecurity> security;
};

class LegacyGuard {
public:
  LegacyGuard()
    : types(rfb::SecurityClient::secTypes.getValueStr()),
      priority(rfb::Security::GnuTLSPriority.getValueStr()),
      ca(rfb::CSecurityTLS::X509CA.getValueStr()),
      crl(rfb::CSecurityTLS::X509CRL.getValueStr()) {}
  ~LegacyGuard()
  {
    rfb::SecurityClient::secTypes.setParam(types.c_str());
    rfb::Security::GnuTLSPriority.setParam(priority.c_str());
    rfb::CSecurityTLS::X509CA.setParam(ca.c_str());
    rfb::CSecurityTLS::X509CRL.setParam(crl.c_str());
  }
private:
  std::string types, priority, ca, crl;
};

} // namespace

class ClientTLS : public ::testing::Test {
protected:
  void SetUp() override
  {
    check(gnutls_global_init());
    initialized = true;
    std::string path = (std::filesystem::temp_directory_path() / "tidyvnc-tls-XXXXXX").string();
    if (!mkdtemp(&path[0])) throw std::runtime_error("Cannot create TLS fixture directory");
    directory = path;
    check(gnutls_x509_privkey_init(&key));
    check(gnutls_x509_privkey_generate(key, GNUTLS_PK_RSA, 2048, 0));
    makeCertificate(ca, 1, true);
    makeCertificate(leaf, 2, false);
    gnutls_datum_t pem = {nullptr, 0};
    check(gnutls_x509_crt_export2(ca, GNUTLS_X509_FMT_PEM, &pem));
    writePEM("ca.pem", pem);

    check(gnutls_x509_crl_init(&crl));
    check(gnutls_x509_crl_set_version(crl, 2));
    check(gnutls_x509_crl_set_this_update(crl, time(nullptr) - 3600));
    check(gnutls_x509_crl_set_next_update(crl, time(nullptr) + 86400));
    const uint8_t serial = 2;
    check(gnutls_x509_crl_set_crt_serial(crl, &serial, 1, time(nullptr) - 1800));
    check(gnutls_x509_crl_sign2(crl, ca, key, GNUTLS_DIG_SHA256, 0));
    check(gnutls_x509_crl_export2(crl, GNUTLS_X509_FMT_PEM, &pem));
    writePEM("revoked.pem", pem);
  }
  void TearDown() override
  {
    if (crl) gnutls_x509_crl_deinit(crl);
    if (leaf) gnutls_x509_crt_deinit(leaf);
    if (ca) gnutls_x509_crt_deinit(ca);
    if (key) gnutls_x509_privkey_deinit(key);
    if (initialized) gnutls_global_deinit();
    std::error_code error;
    if (!directory.empty()) std::filesystem::remove_all(directory, error);
  }
  void makeCertificate(gnutls_x509_crt_t& cert, uint8_t serial, bool authority)
  {
    check(gnutls_x509_crt_init(&cert));
    check(gnutls_x509_crt_set_version(cert, 3));
    check(gnutls_x509_crt_set_serial(cert, &serial, 1));
    check(gnutls_x509_crt_set_activation_time(cert, time(nullptr) - 3600));
    check(gnutls_x509_crt_set_expiration_time(cert, time(nullptr) + 86400));
    check(gnutls_x509_crt_set_dn(cert, authority ? "CN=TidyVNC test CA" : "CN=localhost", nullptr));
    check(gnutls_x509_crt_set_key(cert, key));
    check(gnutls_x509_crt_set_basic_constraints(cert, authority, authority ? 0 : -1));
    check(gnutls_x509_crt_set_key_usage(cert, authority
      ? GNUTLS_KEY_KEY_CERT_SIGN | GNUTLS_KEY_CRL_SIGN
      : GNUTLS_KEY_DIGITAL_SIGNATURE | GNUTLS_KEY_KEY_ENCIPHERMENT));
    if (!authority)
      check(gnutls_x509_crt_set_subject_alt_name(cert, GNUTLS_SAN_DNSNAME,
                                               "localhost", 9, GNUTLS_FSAN_SET));
    check(gnutls_x509_crt_sign2(cert, authority ? cert : ca, key, GNUTLS_DIG_SHA256, 0));
  }
  void writePEM(const char* name, gnutls_datum_t pem)
  {
    std::ofstream file(directory / name, std::ios::binary);
    file.write(reinterpret_cast<const char*>(pem.data), pem.size);
    gnutls_free(pem.data);
    if (!file) throw std::runtime_error("Cannot write TLS fixture");
  }
  rfb::ClientTLSOptions options()
  {
    rfb::ClientTLSOptions result;
    result.priority = "NORMAL:-VERS-ALL:+VERS-TLS1.2";
    result.caFile = (directory / "ca.pem").string();
    return result;
  }
  bool initialized = false;
  std::filesystem::path directory;
  gnutls_x509_privkey_t key = nullptr;
  gnutls_x509_crt_t ca = nullptr, leaf = nullptr;
  gnutls_x509_crl_t crl = nullptr;
};

TEST_F(ClientTLS, ExplicitSnapshotSurvivesCallerAndGlobalChanges)
{
  LegacyGuard restore;
  auto settings = options();
  rfb::SecurityClient policy({rfb::secTypeX509None}, settings);
  settings.priority = "INVALID-PRIORITY";
  settings.caFile.clear();
  settings.crlFile = (directory / "revoked.pem").string();
  rfb::Security::GnuTLSPriority.setParam(settings.priority.c_str());
  rfb::CSecurityTLS::X509CA.setParam("");
  rfb::CSecurityTLS::X509CRL.setParam(settings.crlFile.c_str());
  Exchange exchange(policy, leaf, ca, key);
  EXPECT_NO_THROW(exchange.finish());
  EXPECT_EQ(0u, exchange.connection.certificateStatus);
  EXPECT_EQ(GNUTLS_TLS1_2, gnutls_protocol_get_version(exchange.peer.session));
}

TEST_F(ClientTLS, LegacyDefaultsAreCapturedBeforeHandshake)
{
  LegacyGuard restore;
  auto settings = options();
  rfb::SecurityClient::secTypes.setParam("X509None");
  rfb::Security::GnuTLSPriority.setParam(settings.priority.c_str());
  rfb::CSecurityTLS::X509CA.setParam(settings.caFile.c_str());
  rfb::CSecurityTLS::X509CRL.setParam("");
  rfb::SecurityClient policy;
  rfb::Security::GnuTLSPriority.setParam("INVALID-PRIORITY");
  rfb::CSecurityTLS::X509CA.setParam("");
  rfb::CSecurityTLS::X509CRL.setParam((directory / "revoked.pem").c_str());
  Exchange exchange(policy, leaf, ca, key);
  EXPECT_NO_THROW(exchange.finish());
  EXPECT_EQ(0u, exchange.connection.certificateStatus);
}

TEST_F(ClientTLS, ExplicitEmptyCADoesNotInheritLegacyTrust)
{
  LegacyGuard restore;
  auto settings = options();
  rfb::CSecurityTLS::X509CA.setParam(settings.caFile.c_str());
  settings.caFile.clear();
  rfb::SecurityClient policy({rfb::secTypeX509None}, settings);
  Exchange exchange(policy, leaf, ca, key);
  EXPECT_THROW(exchange.finish(), rfb::auth_cancelled);
  EXPECT_NE(0u, exchange.connection.certificateStatus & GNUTLS_CERT_SIGNER_NOT_FOUND);
}

TEST_F(ClientTLS, RevocationPoliciesRemainIndependentDuringConcurrentHandshakes)
{
  auto settings = options();
  rfb::SecurityClient allowed({rfb::secTypeX509None}, settings);
  settings.crlFile = (directory / "revoked.pem").string();
  rfb::SecurityClient revoked({rfb::secTypeX509None}, settings);
  Exchange first(allowed, leaf, ca, key), second(revoked, leaf, ca, key);
  std::exception_ptr firstError, secondError;
  std::thread firstWorker([&] { try { first.finish(); } catch (...) { firstError = std::current_exception(); } });
  std::thread secondWorker([&] { try { second.finish(); } catch (...) { secondError = std::current_exception(); } });
  firstWorker.join();
  secondWorker.join();
  EXPECT_EQ(nullptr, firstError);
  ASSERT_NE(nullptr, secondError);
  EXPECT_THROW(std::rethrow_exception(secondError), rfb::auth_cancelled);
  EXPECT_NE(0u, second.connection.certificateStatus & GNUTLS_CERT_REVOKED);
}

TEST_F(ClientTLS, InvalidExplicitPriorityDoesNotFallBack)
{
  auto settings = options();
  settings.priority = "INVALID-PRIORITY";
  rfb::SecurityClient policy({rfb::secTypeX509None}, settings);
  Exchange exchange(policy, leaf, ca, key);
  EXPECT_THROW(exchange.finish(), rdr::tls_error);
  EXPECT_EQ(0u, exchange.toServer.length());
}

// Every CSecurityTLS pairs gnutls_global_init/deinit. Constructing and destroying
// other sessions' security objects must not disturb handshakes in progress; this
// relies on GnuTLS >= 3.3's thread-safe, reference-counted global lifetime.
TEST_F(ClientTLS, GlobalLifetimeChurnDoesNotDisturbActiveHandshakes)
{
  auto settings = options();
  rfb::SecurityClient policy({rfb::secTypeX509None}, settings);
  std::atomic<bool> running{true};
  std::atomic<unsigned> churned{0};
  std::mutex errorLock;
  std::exception_ptr churnError;
  std::vector<std::thread> churners;
  for (int i = 0; i < 2; ++i)
    churners.emplace_back([&] {
      try {
        while (running.load()) {
          TestConnection connection(policy);
          connection.setServerName("localhost");
          auto security = connection.makeTLS();
          ++churned;
        }
      } catch (...) {
        std::lock_guard<std::mutex> lock(errorLock);
        if (!churnError) churnError = std::current_exception();
        running = false;
      }
    });
  std::exception_ptr handshakeError;
  for (int i = 0; i < 8 && !handshakeError; ++i) {
    try { Exchange exchange(policy, leaf, ca, key); exchange.finish(); }
    catch (...) { handshakeError = std::current_exception(); }
  }
  running = false;
  for (auto& thread : churners) thread.join();
  EXPECT_EQ(nullptr, churnError);
  EXPECT_EQ(nullptr, handshakeError);
  EXPECT_GT(churned.load(), 0u);
}
