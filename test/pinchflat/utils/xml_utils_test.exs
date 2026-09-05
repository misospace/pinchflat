defmodule Pinchflat.Utils.XmlUtilsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.XmlUtils

  describe "safe/1" do
    test "escapes invalid characters" do
      assert XmlUtils.safe("hello' & <world>") == "hello&#39; &amp; &lt;world&gt;"
    end

    test "converts input to string" do
      assert XmlUtils.safe(42) == "42"
      assert XmlUtils.safe(nil) == ""
    end
  end

  describe "escape_cdata/1" do
    test "escapes ]]> sequences" do
      assert XmlUtils.escape_cdata("hello]]>world") == "hello]]]]><![CDATA[>world"
    end

    test "escapes multiple ]]> sequences" do
      assert XmlUtils.escape_cdata("a]]>b]]>c") == "a]]]]><![CDATA[>b]]]]><![CDATA[>c"
    end

    test "handles empty string" do
      assert XmlUtils.escape_cdata("") == ""
    end

    test "leaves strings without ]]> unchanged" do
      assert XmlUtils.escape_cdata("hello world") == "hello world"
    end

    test "strips XML 1.0 forbidden control characters before escaping break-outs" do
      assert XmlUtils.escape_cdata("a" <> <<0x01>> <> "b" <> <<0x0B>>) == "ab"
      assert XmlUtils.escape_cdata("a" <> <<0x1F>> <> "]]>b") == "a]]]]><![CDATA[>b"
    end
  end

  describe "strip_forbidden_chars/1" do
    test "removes 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F and keeps tab/LF/CR" do
      input =
        "a" <>
          <<0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0B, 0x0C, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
            0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F>> <> "b"

      assert XmlUtils.strip_forbidden_chars(input) == "ab"
      assert XmlUtils.strip_forbidden_chars("a\tb\nc\rd") == "a\tb\nc\rd"
      assert XmlUtils.strip_forbidden_chars("héllo ☃") == "héllo ☃"
      assert XmlUtils.strip_forbidden_chars("😀") == "😀"
    end
  end
end
