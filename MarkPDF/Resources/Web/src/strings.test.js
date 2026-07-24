import { describe, it, expect } from "vitest";
import { STRINGS, t } from "./strings.js";

describe("界面文案表（语言切换）", () => {
  it("zh/en 两表 key 集合一致", () => {
    expect(Object.keys(STRINGS.en).sort()).toEqual(Object.keys(STRINGS.zh).sort());
  });

  it("无空值", () => {
    for (const lang of ["zh", "en"]) {
      for (const [key, value] of Object.entries(STRINGS[lang])) {
        expect(value, `${lang}.${key}`).toBeTruthy();
      }
    }
  });

  it("未知 key 原样返回", () => {
    expect(t("__nope__")).toBe("__nope__");
  });
});
