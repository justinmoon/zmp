const EXPECT_TEXT = process.env.ZMP_EXPECT_TEXT ?? "Zig says: 42";
const SELECTOR = process.env.ZMP_EXPECT_SELECTOR ?? 'android=new UiSelector().textContains("Zig says")';

describe("Zig FFI demo", () => {
  it("displays the number from Zig", async () => {
    const element = await $(SELECTOR);
    await element.waitForExist({ timeout: 15000 });
    await expect(element).toHaveText(EXPECT_TEXT);
  });
});
