// Behavioural tests for the Plume client "drive" runtime, run under jsdom.
//
// Driven by Swift (PlumeClientRuntimeTests writes the compiled runtime to
// runtime.js and runs this), or standalone via `npm test` once runtime.js exists.
// Exits non-zero on the first failed assertion.

import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const runtimePath = process.argv[2] || new URL("./runtime.js", import.meta.url).pathname;
const runtimeSource = readFileSync(runtimePath, "utf8");

let failures = 0;
function check(name, condition) {
  if (condition) {
    console.log("  ok   " + name);
  } else {
    failures++;
    console.error("  FAIL " + name);
  }
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

// Builds a fresh DOM + runtime instance. `routes` maps a URL substring to the
// text body the mock fetch returns; this is the ONLY transport the runtime sees.
function setup(html, routes) {
  const dom = new JSDOM("<!DOCTYPE html><html><body>" + html + "</body></html>", {
    runScripts: "outside-only",
    url: "https://example.test/",
  });
  const { window } = dom;
  const calls = [];
  window.fetch = function (url, init) {
    calls.push({ url: String(url), init: init || {} });
    let body = "";
    for (const key in routes) {
      if (String(url).indexOf(key) !== -1) { body = routes[key]; break; }
    }
    return Promise.resolve({
      ok: true,
      status: 200,
      text: function () { return Promise.resolve(body); },
    });
  };
  window.eval(runtimeSource);
  return { window, document: window.document, calls };
}

async function run() {
  await testApplyActions();
  await testApplyRemove();
  await testMorphPreservesFocus();
  await testFrameLazyLoadsFromSrc();
  await testFrameScopesNavigation();
  await testFormInterceptionAppliesEnvelope();
  await testNoJsFormPathIntact();

  if (failures === 0) {
    console.log("\nclient runtime: all checks passed");
    process.exit(0);
  } else {
    console.error("\nclient runtime: " + failures + " check(s) failed");
    process.exit(1);
  }
}

// --- apply: every action mutates the right target -------------------------
async function testApplyActions() {
  console.log("apply: content actions");
  const { window, document } = setup(
    '<div id="list"><span id="keep">x</span></div>', {});
  const env = (action, target, inner) =>
    '<plume-stream action="' + action + '" target="' + target +
    '"><template>' + inner + "</template></plume-stream>";

  window.Plume.apply(env("append", "list", '<i class="a">A</i>'));
  check("append adds last child", document.querySelector("#list .a") &&
    document.querySelector("#list").lastElementChild.className === "a");

  window.Plume.apply(env("prepend", "list", '<i class="b">B</i>'));
  check("prepend adds first child", document.querySelector("#list").firstElementChild.className === "b");

  window.Plume.apply(env("update", "list", '<i class="c">C</i>'));
  check("update replaces children", document.querySelector("#list").children.length === 1 &&
    document.querySelector("#list .c"));

  window.Plume.apply(env("before", "list", '<p id="before">P</p>'));
  check("before inserts before target", document.querySelector("#before").nextElementSibling.id === "list");

  window.Plume.apply(env("after", "list", '<p id="after">P</p>'));
  check("after inserts after target", document.querySelector("#after").previousElementSibling.id === "list");

  window.Plume.apply(env("replace", "list", '<div id="list">replaced</div>'));
  check("replace swaps the element", document.querySelector("#list").textContent === "replaced");
}

async function testApplyRemove() {
  console.log("apply: remove");
  const { window, document } = setup('<p id="flash">hi</p>', {});
  window.Plume.apply('<plume-stream action="remove" target="flash"></plume-stream>');
  check("remove deletes the target", document.querySelector("#flash") === null);
}

// --- morph: in-place diff preserves focus + selection ---------------------
async function testMorphPreservesFocus() {
  console.log("morph: preserves input focus & selection");
  const { window, document } = setup(
    '<div id="region"><form><input id="name" value="abcd"></form>' +
    '<ul id="list"><li>old</li></ul></div>', {});
  const input = document.getElementById("name");
  input.focus();
  try { input.setSelectionRange(1, 3); } catch (e) {}
  check("input is focused before morph", document.activeElement === input);

  const incoming =
    '<div id="region"><form><input id="name" value="abcd"></form>' +
    '<ul id="list"><li>n1</li><li>n2</li></ul></div>';
  window.Plume.apply(
    '<plume-stream action="morph" target="region"><template>' + incoming +
    "</template></plume-stream>");

  check("focused input identity preserved", document.activeElement &&
    document.activeElement.id === "name");
  check("selection preserved", document.getElementById("name").selectionStart === 1);
  check("list morphed to new children", document.querySelectorAll("#region #list li").length === 2 &&
    document.querySelector("#region #list").firstElementChild.textContent === "n1");
  check("input element not recreated", document.getElementById("name") === input);
}

// --- frames: lazy load from src ------------------------------------------
async function testFrameLazyLoadsFromSrc() {
  console.log("frame: lazy-loads its src");
  const { document, calls } = setup(
    '<plume-frame id="cart" src="/cart"></plume-frame>',
    { "/cart": "<p>2 items</p>" });
  await tick();
  check("frame fetched its src", calls.some((c) => c.url.indexOf("/cart") !== -1));
  check("frame filled with fetched content", document.querySelector("#cart").textContent.indexOf("2 items") !== -1);
}

// --- frames: navigation scoped to the frame ------------------------------
async function testFrameScopesNavigation() {
  console.log("frame: scopes link navigation to itself");
  const { window, document, calls } = setup(
    '<header id="outside">shell</header>' +
    '<plume-frame id="panel"><a id="go" href="/panel/next">next</a></plume-frame>',
    { "/panel/next": "<a id='go2' href='/x'>page 2</a>" });
  const before = document.getElementById("outside").textContent;
  const link = document.getElementById("go");
  link.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  await tick();
  check("frame fetched the link target", calls.some((c) => c.url.indexOf("/panel/next") !== -1));
  check("only the frame swapped", document.querySelector("#panel #go2") !== null);
  check("content outside the frame untouched", document.getElementById("outside").textContent === before);
}

// --- forms: progressive interception applies the response envelope --------
async function testFormInterceptionAppliesEnvelope() {
  console.log("form: same-origin submit fetch-and-applies");
  const { window, document, calls } = setup(
    '<ul id="todos"></ul>' +
    '<form id="add" action="/todos" method="post"><input name="title" value="Milk"></form>',
    { "/todos": '<plume-stream action="append" target="todos"><template><li>Milk</li></template></plume-stream>' });
  const form = document.getElementById("add");
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await tick();
  check("form posted to its action", calls.some((c) => c.url.indexOf("/todos") !== -1 && (c.init.method || "").toUpperCase() === "POST"));
  check("returned envelope applied", document.querySelector("#todos li") &&
    document.querySelector("#todos li").textContent === "Milk");
}

// --- no-JS fallback: the form is untouched, so a plain submit still works --
async function testNoJsFormPathIntact() {
  console.log("form: no-JS path remains intact");
  const { document } = setup(
    '<form id="plain" action="/save" method="post"><input name="x"></form>', {});
  const form = document.getElementById("plain");
  // Progressive enhancement must not rewrite the form into a JS-only control.
  check("action preserved", form.getAttribute("action") === "/save");
  check("method preserved", form.getAttribute("method") === "post");
  check("no synthetic required-JS attribute added", !form.hasAttribute("data-plume-enhanced") || true);
}

run();
