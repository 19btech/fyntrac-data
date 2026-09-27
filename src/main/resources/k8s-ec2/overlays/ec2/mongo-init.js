// ============================================
// DB SWITCH
// ============================================
db = db.getSiblingDB('master');

print("⚠️ Starting cleanup...");

// ============================================
// CLEANUP
// ============================================
db.users.deleteMany({});
db.tenants.deleteMany({});
db.merchants.deleteMany({});

print("✅ All collections cleaned");

// ============================================
// MERCHANT
// ============================================
const MERCHANT_ID = ObjectId("67171f54dcbd9e7e9a527001");

db.merchants.insertOne({
    _id: MERCHANT_ID,
    merchantCode: "MRC001",
    name: "Fyntrac Global",
    status: "ACTIVE",
    createdAt: new Date(),
    updatedAt: new Date()
});

// ============================================
// USERS
// ============================================
const USERS = [
    {
        _id: ObjectId("67171f54dcbd9e7e9a527801"),
        username: "rahmed",
        firstName: "Rafay",
        lastName: "Ahmed",
        email: "rahmed@19btech.com"
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527802"),
        username: "uabbas",
        firstName: "Urooj",
        lastName: "Abbas",
        email: "uabbas@19btech.com"
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527803"),
        username: "ajaffar",
        firstName: "Ali",
        lastName: "Jaffar",
        email: "ajaffar@19btech.com"
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527804"),
        username: "rhassan",
        firstName: "Raheel",
        lastName: "Hassan",
        email: "raheelhassan3615@gmail.com"
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527805"),
        username: "bkhan",
        firstName: "Behram",
        lastName: "Khan",
        email: "BehramHkhan@gmail.com"
    },
    {
        _id: ObjectId("6aa320d2e6fb38658923d4ec"),
        username: "azafar",
        firstName: "Asad",
        lastName: "Zafar",
        email: "asaduzzafar@gmail.com"
    }
];

// ============================================
// CLIENT TENANTS (assigned to ALL users)
// ============================================
// Fixed IDs in their own "71..." range so they never collide with generateTenantId()'s "70..." range.
const CLIENT_TENANT_PREFIX = "HEARST_SANDBOX_";
const CLIENT_TENANT_CODES = [
    "DSH", "CLG", "RUN", "COS", "MHL", "POP", "GHK", "OMC", "TOC", "HBU",
    "ESQ", "WHL", "BIC", "PRE", "EDC", "HAR", "ROA", "VER", "ELM", "CDB"
];

// ============================================
// SHARED TENANTS (COMMON)
// ============================================
const SHARED_TENANTS = [
    { code: "TNT001", name: "Common Tenant 1" },
    { code: "TNT002", name: "Common Tenant 2" },
    { code: "TNT003", name: "Common Tenant 3" },
    { code: "TNT004", name: "Common Tenant 4" }
];

let tenantCounter = 1;

// helper for ObjectId
function generateTenantId(counter) {
    return ObjectId("7" + counter.toString().padStart(23, "0"));
}

// ============================================
// INSERT SHARED TENANTS
// ============================================
print("🚀 Inserting shared tenants...");

const sharedTenantIds = [];

SHARED_TENANTS.forEach((tenant, index) => {
    const tenantId = generateTenantId(tenantCounter++);
    sharedTenantIds.push(tenantId);

    db.tenants.insertOne({
        _id: tenantId,
        tenantCode: tenant.code,
        name: tenant.name,
        merchantId: MERCHANT_ID,
        userIds: USERS.map(u => u._id), // ALL USERS
        status: "ACTIVE",
        createdAt: new Date(),
        updatedAt: new Date()
    });
});

print("✅ Shared tenants inserted");

// ============================================
// PRIVATE TENANTS (PER USER)
// ============================================
print("🚀 Inserting private tenants...");

USERS.forEach(user => {
    user.tenantIds = [...sharedTenantIds]; // start with shared

    for (let i = 1; i <= 3; i++) {
        const tenantId = generateTenantId(tenantCounter++);

        user.tenantIds.push(tenantId);

        db.tenants.insertOne({
            _id: tenantId,
            tenantCode: `TNT_${user.username.toUpperCase()}_${i}`,
            name: `${user.firstName} ${user.lastName} Tenant ${i}`,
            merchantId: MERCHANT_ID,
            userIds: [user._id], // ONLY THIS USER
            status: "ACTIVE",
            createdAt: new Date(),
            updatedAt: new Date()
        });
    }
});

print("✅ Private tenants inserted");

// ============================================
// INSERT CLIENT TENANTS
// ============================================
print("🚀 Inserting client tenants...");

const clientTenantUsers = USERS; // ALL USERS

CLIENT_TENANT_CODES.forEach((code, index) => {
    const tenantId = ObjectId("71" + (index + 1).toString().padStart(22, "0"));

    clientTenantUsers.forEach(user => user.tenantIds.push(tenantId));

    db.tenants.insertOne({
        _id: tenantId,
        tenantCode: CLIENT_TENANT_PREFIX + code,
        name: CLIENT_TENANT_PREFIX + code,
        merchantId: MERCHANT_ID,
        userIds: clientTenantUsers.map(u => u._id),
        status: "ACTIVE",
        createdAt: new Date(),
        updatedAt: new Date()
    });
});

print("✅ Client tenants inserted");

// ============================================
// INSERT USERS
// ============================================
print("🚀 Inserting users...");

USERS.forEach(user => {
    db.users.insertOne({
        _id: user._id,
        username: user.username,
        firstName: user.firstName,
        lastName: user.lastName,
        fullName: `${user.firstName} ${user.lastName}`,
        email: user.email,
        tenantIds: user.tenantIds, // shared + private
        merchantId: MERCHANT_ID,
        roles: [{ name: "ADMIN" }],
        active: true,
        createdAt: new Date(),
        updatedAt: new Date()
    });
});

print("🎉 SUCCESS: Seed completed");

// ============================================
// SUMMARY
// ============================================
print("--------------------------------------------------");
print("Users: " + USERS.length);
print("Shared Tenants: 4");
print("Private Tenants per user: 3");
print("Client Tenants: " + CLIENT_TENANT_CODES.length);
print("Total Tenants: " + (4 + USERS.length * 3 + CLIENT_TENANT_CODES.length));
print("--------------------------------------------------");
