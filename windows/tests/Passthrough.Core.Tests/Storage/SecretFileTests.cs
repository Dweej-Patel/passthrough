using System.Text;
using Passthrough.Core.Storage;
using Xunit;

namespace Passthrough.Core.Tests.Storage;

public class SecretFileTests
{
    [Fact]
    public void FileName_SlotsDifferingOnlyInCase_GetDifferentFiles()
    {
        // NTFS ignores case: "token.android.abc" and "token.android.ABC" must not share a file.
        Assert.NotEqual(
            SecretFile.FileName("token.android.abc").ToUpperInvariant(),
            SecretFile.FileName("token.android.ABC").ToUpperInvariant());
    }

    [Theory]
    [InlineData("token.android.")]
    [InlineData("token.iphone.00008110-001A2B3C4D5E801E")]
    [InlineData("token.ipad.ÄÖÜ")]
    public void FileName_IsShortLowercaseHexAndStable(string slot)
    {
        var name = SecretFile.FileName(slot);
        Assert.Matches("^[0-9a-f]{64}\\.bin$", name);
        Assert.Equal(name, SecretFile.FileName(slot));
    }

    [Fact]
    public void FileName_LongSlot_StaysShort()
    {
        Assert.Equal(68, SecretFile.FileName("token.android." + new string('x', 400)).Length);
    }

    [Fact]
    public void Encode_RoundTripsSlotAndValue()
    {
        var bytes = SecretFile.Encode("token.android.R58M123", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8");
        Assert.Equal(("token.android.R58M123", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), SecretFile.Decode(bytes));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("{\"slot\":\"token.android.x\"}")]
    [InlineData("{\"slot\":1,\"value\":\"v\"}")]
    [InlineData("[1,2]")]
    public void Decode_AnythingElse_IsNull(string text)
    {
        Assert.Null(SecretFile.Decode(Encoding.UTF8.GetBytes(text)));
    }
}
