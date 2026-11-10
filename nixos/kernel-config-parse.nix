# 把一份 .config 文本解析成 nixpkgs 内核包用的 config 形状
# （isSet/getValue/isYes/isNo/isModule/isEnabled/isDisabled，见 nixpkgs
# pkgs/os-specific/linux/kernel/build.nix）。给自建/预编译内核当 config 参数用。
{ lib }:
file:
let
  attrName = attr: "CONFIG_" + attr;
  entries = builtins.listToAttrs (
    builtins.concatMap (
      line:
      let
        m = builtins.match "CONFIG_([A-Za-z0-9_]+)=(.*)" line;
      in
      lib.optional (m != null) {
        name = attrName (builtins.elemAt m 0);
        value =
          let
            v = builtins.elemAt m 1;
          in
          if v == "y" || v == "m" || v == "n" then
            v
          else if builtins.match "\".*\"" v != null then
            builtins.substring 1 (builtins.stringLength v - 2) v
          else
            v;
      }
    ) (lib.splitString "\n" (builtins.readFile file))
  );
  get = attr: entries.${attrName attr} or null;
in
{
  isSet = attr: builtins.hasAttr (attrName attr) entries;
  getValue = get;
  isYes = attr: get attr == "y";
  isNo = attr: get attr == "n";
  isModule = attr: get attr == "m";
  isEnabled = attr: get attr == "m" || get attr == "y";
  isDisabled = attr: !(builtins.hasAttr (attrName attr) entries) || get attr == "n";
} // entries
