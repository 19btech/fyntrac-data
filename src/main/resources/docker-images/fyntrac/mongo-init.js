// Switch DB
db = db.getSiblingDB('master');

print("⚠️ Cleaning existing data...");

// ------------------------------
// Cleanup Collections
// ------------------------------
db.users.deleteMany({});
db.tenants.deleteMany({});
db.merchants.deleteMany({});

print("✅ Collections cleaned");

// ------------------------------
// Merchant
// ------------------------------
const MERCHANT_ID = ObjectId("67171f54dcbd9e7e9a527001");

db.merchants.insertOne({
    _id: MERCHANT_ID,
    merchantCode: "MRC001",
    name: "Fyntrac Global",
    description: "Leading financial platform for multi-tenant services",
    industryType: "FinTech",
    contactEmail: "support@fyntrac.com",
    contactPhone: "+92-300-1234567",
    address: {
        street: "123 Financial Avenue",
        city: "Karachi",
        state: "Sindh",
        postalCode: "75500",
        country: "Pakistan"
    },
    status: "ACTIVE",
    createdAt: new Date(),
    updatedAt: new Date()
});

// ------------------------------
// Users + Tenants Definition
// ------------------------------
const USERS = [
    {
        _id: ObjectId("67171f54dcbd9e7e9a527801"),
        username: "Rafay",
        email: "rahmed@19btech.com",
        tenantIds: [
            ObjectId("700000000000000000000001"),
            ObjectId("700000000000000000000002"),
            ObjectId("700000000000000000000003")
        ]
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527802"),
        username: "Urooj",
        email: "uabbas@19btech.com",
        tenantIds: [
            ObjectId("700000000000000000000004"),
            ObjectId("700000000000000000000005"),
            ObjectId("700000000000000000000006")
        ]
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527803"),
        username: "Jaffar",
        email: "ajaffar@19btech.com",
        tenantIds: [
            ObjectId("700000000000000000000007"),
            ObjectId("700000000000000000000008"),
            ObjectId("700000000000000000000009")
        ]
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527804"),
        username: "Raheel",
        email: "raheelhassan3615@gmail.com",
        tenantIds: [
            ObjectId("700000000000000000000010"),
            ObjectId("700000000000000000000011"),
            ObjectId("700000000000000000000012")
        ]
    },
    {
        _id: ObjectId("67171f54dcbd9e7e9a527805"),
        username: "Behram",
        email: "BehramHkhan@gmail.com",
        tenantIds: [
            ObjectId("700000000000000000000013"),
            ObjectId("700000000000000000000014"),
            ObjectId("700000000000000000000015")
        ]
    }
];

// ------------------------------
// Insert Tenants (Isolated)
// ------------------------------
print("🚀 Inserting tenants...");

USERS.forEach(user => {
    user.tenantIds.forEach((tenantId, index) => {
        db.tenants.insertOne({
            _id: tenantId,
            tenantCode: `TNT_${user.username.toUpperCase()}_${index + 1}`,
            name: `${user.username} Tenant ${index + 1}`,
            merchantId: MERCHANT_ID,
            userIds: [user._id], // strict isolation
            status: "ACTIVE",
            createdAt: new Date(),
            updatedAt: new Date()
        });
    });
});

// ------------------------------
// Insert Users
// ------------------------------
print("🚀 Inserting users...");

USERS.forEach(user => {
    db.users.insertOne({
        _id: user._id,
        username: user.username,
        email: user.email,
        tenantIds: user.tenantIds,
        merchantId: MERCHANT_ID,
        roles: [{ name: "ADMIN" }],
        active: true,
        createdAt: new Date(),
        updatedAt: new Date()
    });
});

print("✅ Cleanup + fresh isolated data inserted successfully!");
