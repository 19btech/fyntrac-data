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
// MERCHANT SETUP
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

print("✅ Merchant inserted");

// ============================================
// USERS CONFIG
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
    }
];

// ============================================
// TENANT GENERATION LOGIC
// ============================================
let tenantCounter = 1;

function generateTenantId(counter) {
    return ObjectId(
        "7" + counter.toString().padStart(23, "0")
    );
}

print("🚀 Generating tenants...");

USERS.forEach(user => {
    user.tenantIds = [];

    for (let i = 1; i <= 3; i++) {
        const tenantId = generateTenantId(tenantCounter++);

        user.tenantIds.push(tenantId);

        db.tenants.insertOne({
            _id: tenantId,
            tenantCode: `TNT_${user.username.toUpperCase()}_${i}`,
            name: `${user.firstName} ${user.lastName} Tenant ${i}`,
            merchantId: MERCHANT_ID,
            userIds: [user._id],
            status: "ACTIVE",
            createdAt: new Date(),
            updatedAt: new Date()
        });
    }
});

print("✅ Tenants inserted");

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
        tenantIds: user.tenantIds,
        merchantId: MERCHANT_ID,
        roles: [
            {
                name: "ADMIN"
            }
        ],
        active: true,
        createdAt: new Date(),
        updatedAt: new Date()
    });
});

print("✅ Users inserted");

// ============================================
// SUMMARY OUTPUT
// ============================================
print("🎉 SUCCESS: Database reset + seeded");

print("--------------------------------------------------");
print("Users Created: " + USERS.length);
print("Tenants Created: " + (USERS.length * 3));
print("Each user has 3 isolated tenants");
print("--------------------------------------------------");
