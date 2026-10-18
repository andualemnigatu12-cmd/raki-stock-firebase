import { initializeApp } from "https://www.gstatic.com/firebasejs/12.4.0/firebase-app.js";
import {
  getAuth, onAuthStateChanged, signInWithEmailAndPassword, signOut,
} from "https://www.gstatic.com/firebasejs/12.4.0/firebase-auth.js";
import {
  getFirestore, collection, doc, getDoc, getDocs, addDoc,
  query, where, limit, onSnapshot, runTransaction, serverTimestamp,
} from "https://www.gstatic.com/firebasejs/12.4.0/firebase-firestore.js";

// This is a real Firestore owner workspace; it is not a simulated dashboard.
// Until the owner registers a Firebase Web app and deploys V2 rules, no
// registrations or approvals can be performed.
const $ = id => document.getElementById(id);
const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[c]);
const normalizeName = text => String(text ?? "")
  .toLowerCase().replace(/æ/g, "ae").replace(/œ/g, "oe")
  .normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
  .replace(/[^\\p{L}\\p{N}]+/gu, " ").replace(/\s+/g, " ").trim();
const normalizeBarcode = text => String(text ?? "").replace(/[^A-Za-z0-9]/g, "").toUpperCase();
const formatMoney = amount => new Intl.NumberFormat("en-ET", {
  minimumFractionDigits: 2, maximumFractionDigits: 2,
}).format(Number(amount ?? 0)) + " ETB";

let auth, db, branchId = "", ownerId = "", unsubscribe = [];
let entries = [], products = [], noticeTimer;
let activeView = "pending";

function notify(message, isError = false) {
  const node = $("notice");
  node.textContent = message;
  node.className = isError ? "error" : "";
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { node.textContent = ""; }, 9000);
}
function show(id) {
  for (const name of ["setup", "login", "shell"]) {
    $(name).classList.toggle("hidden", name !== id);
  }
}
function changeView(view) {
  activeView = view;
  document.querySelectorAll(".nav-link").forEach(n =>
    n.classList.toggle("active", n.dataset.view === view));
  for (const name of ["pending", "catalog", "register", "backup"]) {
    $(name + "-view").classList.toggle("hidden", view !== name);
  }
  $("view-heading").textContent = {
    pending: "Pending review", catalog: "Product catalog",
    register: "Manual registration", backup: "Backup & audit",
  }[view];
  if (view === "catalog") renderCatalog();
}

function productId(name, barcode) {
  const slug = branchId.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const code = normalizeBarcode(barcode);
  if (code) return "v2-" + slug + "-b-" + code;
  let hash = 0x811c9dc5;
  const normalized = normalizeName(name);
  for (let i = 0; i < normalized.length; i++) {
    hash ^= normalized.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return "v2-" + slug + "-n-" + hash.toString(16).padStart(8, "0");
}

function candidateProducts(name, barcode) {
  const normalized = normalizeName(name), code = normalizeBarcode(barcode);
  return products.filter(p => (
    (code && normalizeBarcode(p.barcode) && normalizeBarcode(p.barcode) === code) ||
    (normalized && (!code || !normalizeBarcode(p.barcode)) &&
      normalizeName(p.name) === normalized)
  )).slice(0, 25);
}
function renderStats() {
  $("pending-count").textContent = entries.filter(e => e.status === "pending").length.toLocaleString();
  $("product-count").textContent = products.length.toLocaleString();
  $("unit-count").textContent = products.reduce((sum,p) => sum + Number(p.stockQty ?? 0), 0).toLocaleString();
}
function entryHTML(e) {
  const qty = Number(e.quantity ?? 0);
  const name = e.nameCandidate ?? "", barcode = e.barcodeCandidate ?? "";
  return `
    <form class="entry" data-entry-id="${esc(e.id)}">
      <div class="entry-top"><div>
        <h3>${esc(name || "Product name needs review")}</h3>
        <small>Qty ${qty} · ${esc(e.section || "No shelf assigned")} · ${esc(e.barcodeCandidate || "No barcode")}</small>
        <small>Photo: ${e.photoState === "local_only" ? "captured on phone, not available on website" : "not uploaded"}</small>
      </div><span class="tag">PENDING</span></div>
      <div class="entry-content">
        <label>Official name + size<input name="name" required value="${esc(name)}"></label>
        <label>Barcode<input name="barcode" value="${esc(barcode)}"></label>
        <label>Selling price (ETB)<input name="price" type="number" min="0.01" step="0.01" required></label>
        <label class="entry-wide">Existing product / quantity merge
          <select name="existing"><option value="">New product (no match)</option></select>
        </label>
      </div>
      <div class="entry-actions"><button type="submit" class="primary">Approve + add ${qty} units</button></div>
    </form>`;
}
function updateExistingSelect(form) {
  const name = form.elements.namedItem("name").value;
  const barcode = form.elements.namedItem("barcode").value;
  const matches = candidateProducts(name, barcode);
  const select = form.elements.namedItem("existing");
  const previous = select.value;
  select.replaceChildren(new Option("New product (no match)", ""));
  for (const p of matches) {
    select.add(new Option(p.name + " · stock " + p.stockQty + " · " + formatMoney(p.sellingPrice), p.id));
  }
  if (matches.some(p => p.id === previous)) select.value = previous;
  if (matches.length) {
    select.options[0].text = "Select an existing product to ADD quantity";
    select.options[0].disabled = true;
    if (!select.value) select.selectedIndex = 0;
  }
}
function renderPending() {
  const pending = entries.filter(e => e.status === "pending")
    .sort((a,b) => (a.createdAt?.seconds ?? 0) - (b.createdAt?.seconds ?? 0));
  $("pending-list").innerHTML = pending.length
    ? pending.map(entryHTML).join("")
    : '<p class="empty">No pending registrations. New captures will appear here after syncing.</p>';
  $("pending-list").querySelectorAll("form[data-entry-id]").forEach(form => {
    updateExistingSelect(form);
    for (const fieldName of ["name", "barcode"]) {
      form.elements.namedItem(fieldName).addEventListener("input", () => {
        updateExistingSelect(form);
      });
    }
    form.elements.namedItem("existing").addEventListener("change", () => {
      const matched = products.find(p => p.id === form.elements.namedItem("existing").value);
      const price = form.elements.namedItem("price");
      if (matched && !price.value && Number(matched.sellingPrice) > 0) {
        price.value = matched.sellingPrice;
      }
    });
    form.addEventListener("submit", async event => {
      event.preventDefault();
      const button = form.querySelector('[type="submit"]');
      button.disabled = true;
      try {
        const name = form.elements.namedItem("name").value.trim();
        const barcode = normalizeBarcode(form.elements.namedItem("barcode").value);
        const price = Number(form.elements.namedItem("price").value);
        const existing = form.elements.namedItem("existing").value;
        const matches = candidateProducts(name, barcode);
        if (matches.length && !existing) {
          throw new Error("An existing product matches. Select it and verify the variant before approving.");
        }
        const id = await approve(form.dataset.entryId, name, barcode, price, existing);
        notify("Approved and added stock to " + id);
      } catch (error) {
        notify(error.message || String(error), true);
      } finally {
        button.disabled = false;
      }
    });
  });
}

async function approve(entryId, name, barcode, price, chosenId) {
  name = name.trim();
  const normalized = normalizeName(name);
  if (!normalized) throw new Error("Confirm the product name and size.");
  if (!Number.isFinite(price) || price <= 0) throw new Error("Price must be greater than zero.");
  const id = chosenId || productId(name, barcode);
  const entryRef = doc(db, "registration_entries", entryId);
  const productRef = doc(db, "products", id);
  const movementRef = doc(db, "inventory_movements", entryId);

  return runTransaction(db, async tx => {
    const entrySnap = await tx.get(entryRef);
    if (!entrySnap.exists()) throw new Error("Entry no longer exists.");
    const entry = entrySnap.data();
    if (entry.branchId !== branchId) throw new Error("Wrong branch.");
    if (entry.status === "approved") return entry.linkedProductId;
    if (entry.status !== "pending") throw new Error("Entry is no longer pending.");
    if (!Number.isInteger(entry.quantity) || entry.quantity <= 0) {
      throw new Error("Counted quantity must be a positive integer.");
    }
    const priorMove = await tx.get(movementRef);
    if (priorMove.exists()) throw new Error("This entry already changed stock.");
    const oldProduct = await tx.get(productRef);
    const prior = oldProduct.exists() ? oldProduct.data() : null;
    if (prior && prior.branchId !== branchId) throw new Error("Wrong product branch.");
    const oldCode = normalizeBarcode(prior?.barcode);
    if (oldCode && barcode && oldCode !== barcode) {
      throw new Error("Different barcode. Verify package size/variant.");
    }
    const oldName = normalizeName(prior?.name);
    if (prior && !oldCode && !barcode && oldName && oldName !== normalized) {
      throw new Error("Existing product name/variant differs. Do not merge.");
    }
    const before = Number(prior?.stockQty ?? 0);
    if (!Number.isInteger(before) || before < 0) {
      throw new Error("Existing stock quantity is invalid.");
    }
    const now = serverTimestamp();
    const recordedBarcode = barcode || oldCode;
    tx.set(productRef, {
      branchId, name, normalizedName: normalized, barcode: recordedBarcode || null,
      catalogKey: recordedBarcode ? "barcode:" + recordedBarcode : "name:" + normalized,
      sellingPrice: price, stockQty: before + entry.quantity, active: true,
      schemaVersion: 2, lastMovementId: entryId,
      updatedAt: now, updatedBy: ownerId,
      ...(!prior ? { createdAt: now, createdBy: ownerId, registrationSource: "reviewed_entry" } : {}),
    }, { merge: true });
    tx.set(movementRef, {
      branchId, productId: id, registrationEntryId: entryId,
      type: "opening_count", quantityDelta: entry.quantity,
      beforeQty: before, afterQty: before + entry.quantity,
      createdAt: now, createdBy: ownerId, capturedBy: entry.createdBy,
    });
    tx.update(entryRef, {
      status: "approved", reviewedName: name,
      reviewedBarcode: barcode || null, reviewedSellingPrice: price,
      linkedProductId: id, approvedAt: now, approvedBy: ownerId,
    });
    return id;
  }, { maxAttempts: 5 });
}
function renderCatalog() {
  const needle = $("catalog-search").value.trim().toLowerCase();
  const data = products.filter(p => (
    (p.name || "").toLowerCase().includes(needle) ||
    (p.barcode || "").toLowerCase().includes(needle)
  )).sort((a,b) => (a.name || "").localeCompare(b.name || ""));
  $("catalog-rows").innerHTML = data.length ? data.map(p => `
    <tr><td>${esc(p.name)}</td><td>${esc(p.barcode || "—")}</td>
    <td>${formatMoney(p.sellingPrice)}</td><td>${Number(p.stockQty ?? 0)}</td></tr>
  `).join("") : '<tr><td colspan="4" class="empty">No matching approved V2 products.</td></tr>';
}
function subscribe() {
  unsubscribe.forEach(fn => fn());
  unsubscribe = [];
  unsubscribe.push(onSnapshot(
    query(collection(db, "registration_entries"), where("branchId", "==", branchId), limit(2000)),
    snap => {
      entries = snap.docs.map(d => ({ id: d.id, ...d.data() }));
      renderStats(); renderPending();
    }, error => notify("Registration access failed: " + error.message, true),
  ));
  unsubscribe.push(onSnapshot(
    query(collection(db, "products"), where("branchId", "==", branchId), limit(2000)),
    snap => {
      products = snap.docs.map(d => ({ id: d.id, ...d.data() }))
        .filter(p => p.schemaVersion === 2 && p.active !== false);
      renderStats(); renderCatalog(); renderPending();
    }, error => notify("Product access failed: " + error.message, true),
  ));
}

async function startSession(user) {
  unsubscribe.forEach(fn => fn());
  unsubscribe = [];
  const profile = await getDoc(doc(db, "users", user.uid));
  const data = profile.data();
  if (!profile.exists() || data.role !== "owner" || data.active !== true ||
      typeof data.branchId !== "string" || !data.branchId) {
    await signOut(auth);
    throw new Error("Only active owners with a branch can sign in.");
  }
  branchId = data.branchId;
  ownerId = user.uid;
  $("account-summary").textContent = data.displayName || user.email;
  show("shell");
  changeView(activeView);
  subscribe();
}

async function startFirebase(config) {
  try {
    const app = initializeApp({
      apiKey: config.apiKey, projectId: config.projectId, appId: config.appId,
      authDomain: config.projectId + ".firebaseapp.com",
    });
    db = getFirestore(app);
    auth = getAuth(app);
    onAuthStateChanged(auth, async user => {
      if (!user) { unsubscribe.forEach(fn => fn()); show("login"); return; }
      try {
        await startSession(user);
      } catch (error) {
        notify(error.message || String(error), true);
        show("login");
      }
    });
  } catch (error) {
    notify("Firebase setup failed: " + error.message, true);
    show("setup");
  }
}

$("config-form").addEventListener("submit", async event => {
  event.preventDefault();
  const config = {
    apiKey: $("apiKey").value.trim(),
    projectId: $("projectId").value.trim(),
    appId: $("appId").value.trim(),
  };
  localStorage.setItem("raki-v2-firebase-config", JSON.stringify(config));
  await startFirebase(config);
});
$("login-form").addEventListener("submit", async event => {
  event.preventDefault();
  try {
    await signInWithEmailAndPassword(auth, $("loginEmail").value.trim(), $("loginPassword").value);
    $("loginPassword").value = "";
  } catch (error) {
    notify("Sign in failed: " + error.message, true);
  }
});
$("reset-config").addEventListener("click", () => {
  localStorage.removeItem("raki-v2-firebase-config");
  location.reload();
});
$("logout").addEventListener("click", async () => {
  await signOut(auth);
});
document.querySelectorAll(".nav-link").forEach(n => {
  n.addEventListener("click", () => changeView(n.dataset.view));
});
$("catalog-search").addEventListener("input", renderCatalog);

$("register-form").addEventListener("submit", async event => {
  event.preventDefault();
  const btn = $("register-submit");
  btn.disabled = true;
  try {
    const name = $("register-name").value.trim();
    const qty = Number($("register-qty").value);
    if (!name || !Number.isInteger(qty) || qty <= 0) {
      throw new Error("Enter a product name and a valid quantity.");
    }
    await addDoc(collection(db, "registration_entries"), {
      branchId, createdBy: ownerId, quantity: qty,
      nameCandidate: name,
      barcodeCandidate: normalizeBarcode($("register-barcode").value),
      productText: $("register-text").value.trim(),
      section: $("register-section").value.trim(),
      localPhotoPath: null, photoState: "none", status: "pending",
      createdAt: serverTimestamp(), schemaVersion: 2,
    });
    $("register-name").value = "";
    $("register-barcode").value = "";
    $("register-qty").value = "";
    $("register-text").value = "";
    notify("Registration saved for owner approval.");
    changeView("pending");
  } catch (error) {
    notify("Could not save registration: " + error.message, true);
  } finally { btn.disabled = false; }
});

$("export-json").addEventListener("click", async () => {
  const button = $("export-json");
  button.disabled = true;
  try {
    const names = ["registration_entries", "products", "inventory_movements"];
    const payload = {
      exportedAt: new Date().toISOString(), branchId, schema: "Raki Stock V2",
      collections: {},
    };
    for (const name of names) {
      const snapshot = await getDocs(query(collection(db, name), where("branchId", "==", branchId), limit(10000)));
      if (snapshot.size === 10000) {
        throw new Error(name + " hit the 10,000-document export limit. Split/export with pagination before relying on this backup.");
      }
      payload.collections[name] = snapshot.docs.map(d => ({ id: d.id, ...d.data() }));
    }
    const bytes = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(bytes);
    const a = document.createElement("a");
    a.href = url;
    a.download = "raki-stock-backup-" + new Date().toISOString().slice(0, 10) + ".json";
    a.click();
    URL.revokeObjectURL(url);
    notify("Backup downloaded. Open the file and keep two independent copies.");
  } catch (error) {
    notify("Backup failed: " + error.message, true);
  } finally { button.disabled = false; }
});

try {
  const saved = JSON.parse(localStorage.getItem("raki-v2-firebase-config") || "null");
  if (saved?.apiKey && saved?.projectId && saved?.appId) {
    await startFirebase(saved);
  } else {
    show("setup");
  }
} catch (_) {
  show("setup");
}
