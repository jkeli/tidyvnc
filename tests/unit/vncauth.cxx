/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>

#include <rfb/CConnection.h>
#include <rfb/CSecurityVncAuth.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>

#include <array>
#include <string>
#include <vector>

namespace {

class AuthConnection : public rfb::CConnection {
public:
  explicit AuthConnection(const std::string& password) : suppliedPassword(password) {}

  void getUserPasswd(bool secure, std::string* user, std::string* password) override
  {
    EXPECT_FALSE(secure);
    EXPECT_EQ(nullptr, user);
    *password = suppliedPassword;
  }
  bool verifyCertificate(unsigned int, const uint8_t*, size_t) override { return false; }
  bool verifyHostKey(const uint8_t*, size_t, const char*) override { return false; }
  void initDone() override { FAIL() << "No desktop initialization expected"; }
  void bell() override { FAIL() << "No bell expected during authentication"; }

private:
  std::string suppliedPassword;
};

} // namespace

TEST(VncAuth, ClientResponseCompatibility)
{
  const uint8_t challenge[] = {0, 1, 2, 3, 4, 5, 6, 7,
                               8, 9, 10, 11, 12, 13, 14, 15};
  struct Fixture {
    const char* password;
    std::array<uint8_t, 16> expected;
  };
  // Responses captured before replacing the global DES schedule (7daf39fa).
  const Fixture fixtures[] = {
    {"password", {{0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb,
                    0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2}}},
    {"password-truncated", {{0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb,
                              0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2}}},
    {"secret", {{0xee, 0x22, 0x53, 0x9f, 0x33, 0xa5, 0x98, 0x3e,
                  0xc1, 0x2f, 0x9c, 0x2e, 0xdb, 0xc9, 0x95, 0xdd}}},
    {"", {{0x49, 0x1e, 0x89, 0x0d, 0xe9, 0xac, 0xe9, 0x32,
            0x83, 0x8a, 0x49, 0x79, 0x2f, 0x22, 0x13, 0xf3}}},
  };
  for (const auto& fixture : fixtures) {
    SCOPED_TRACE(fixture.password);
    rdr::MemInStream input(challenge, sizeof(challenge));
    rdr::MemOutStream output;
    AuthConnection connection(fixture.password);
    connection.setStreams(&input, &output);
    rfb::CSecurityVncAuth auth(&connection);
    ASSERT_TRUE(auth.processMsg());
    EXPECT_EQ(std::vector<uint8_t>(fixture.expected.begin(), fixture.expected.end()),
              std::vector<uint8_t>(output.data(), output.data() + output.length()));
  }
}
