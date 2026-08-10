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
  end
end
