// Switch to master DB
db = db.getSiblingDB('master');

// ------------------------------
// Merchant Collection
// ------------------------------
if (!db.getCollectionNames().includes('merchants')) {
    db.createCollection('merchants');
}

db.merchants.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a527001") },
    {
        $set: {
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
            tenantIds: [
                ObjectId("67171f54dcbd9e7e9a52768f"),
                ObjectId("67171f8adcbd9e7e9a527690"),
                ObjectId("687ee8c4fcbb23ffa95b4ad3")
            ],
            status: "ACTIVE",
            createdAt: ISODate("2024-10-01T00:00:00Z"),
            updatedAt: ISODate("2024-10-01T00:00:00Z")
        }
    },
    { upsert: true }
);

// ------------------------------
// Tenant Collection
// ------------------------------
if (!db.getCollectionNames().includes('tenants')) {
    db.createCollection('tenants');
}

db.tenants.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a52768f") },
    {
        $set: {
            tenantCode: "TNT001",
            name: "Tenant One",
            description: "Main production tenant",
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            timezone: "Asia/Karachi",
            currency: "PKR",
            locale: "en_PK",
            userIds: [
                ObjectId("67171f54dcbd9e7e9a527801"),
                ObjectId("67171f54dcbd9e7e9a527802")
            ],
            status: "ACTIVE",
            createdAt: ISODate("2024-10-02T00:00:00Z"),
            updatedAt: ISODate("2024-10-02T00:00:00Z")
        }
    },
    { upsert: true }
);

db.tenants.updateOne(
    { _id: ObjectId("67171f8adcbd9e7e9a527690") },
    {
        $set: {
            tenantCode: "TNT002",
            name: "Tenant Two",
            description: "Secondary tenant for staging environment",
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            timezone: "Asia/Dubai",
            currency: "AED",
            locale: "en_AE",
            userIds: [
                ObjectId("67171f54dcbd9e7e9a527802"),
                ObjectId("67171f54dcbd9e7e9a527803")
            ],
            status: "TEST",
            createdAt: ISODate("2024-10-03T00:00:00Z"),
            updatedAt: ISODate("2024-10-03T00:00:00Z")
        }
    },
    { upsert: true }
);

db.tenants.updateOne(
    { _id: ObjectId("687ee8c4fcbb23ffa95b4ad3") },
    {
        $set: {
            tenantCode: "TNT003",
            name: "Tenant Three",
            description: "Internal test tenant",
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            timezone: "Asia/Karachi",
            currency: "USD",
            locale: "en_US",
            userIds: [
                ObjectId("67171f54dcbd9e7e9a527803")
            ],
            status: "DISABLED",
            createdAt: ISODate("2024-10-05T00:00:00Z"),
            updatedAt: ISODate("2024-10-05T00:00:00Z")
        }
    },
    { upsert: true }
);

// ------------------------------
// User Collection
// ------------------------------
if (!db.getCollectionNames().includes('users')) {
    db.createCollection('users');
}

db.users.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a527801") },
    {
        $set: {
            username: "merchantAdmin",
            email: "admin@fyntrac.com",
            passwordHash: "hashed-password-1",
            firstName: "Ali",
            lastName: "Raza",
            phoneNumber: "+92-300-9876543",
            tenantIds: [ ObjectId("67171f54dcbd9e7e9a52768f") ],
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            roles: [
                { name: "ADMIN", description: "Full system access" }
            ],
            verified: true,
            active: true,
            lastLoginAt: ISODate("2024-10-05T10:00:00Z"),
            createdAt: ISODate("2024-10-01T00:00:00Z"),
            updatedAt: ISODate("2024-10-05T10:00:00Z")
        }
    },
    { upsert: true }
);

db.users.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a527802") },
    {
        $set: {
            username: "tenantManager",
            email: "manager@fyntrac.com",
            passwordHash: "hashed-password-2",
            firstName: "Sara",
            lastName: "Khan",
            phoneNumber: "+971-55-1234567",
            tenantIds: [
                ObjectId("67171f54dcbd9e7e9a52768f"),
                ObjectId("67171f8adcbd9e7e9a527690")
            ],
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            roles: [
                { name: "MANAGER", description: "Tenant operations manager" }
            ],
            verified: true,
            active: true,
            lastLoginAt: ISODate("2024-10-06T09:00:00Z"),
            createdAt: ISODate("2024-10-02T00:00:00Z"),
            updatedAt: ISODate("2024-10-06T09:00:00Z")
        }
    },
    { upsert: true }
);

db.users.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a527803") },
    {
        $set: {
            username: "auditor",
            email: "auditor@fyntrac.com",
            passwordHash: "hashed-password-3",
            firstName: "Bilal",
            lastName: "Ahmed",
            phoneNumber: "+92-333-8889999",
            tenantIds: [
                ObjectId("67171f8adcbd9e7e9a527690"),
                ObjectId("687ee8c4fcbb23ffa95b4ad3")
            ],
            merchantId: ObjectId("67171f54dcbd9e7e9a527001"),
            roles: [
                { name: "AUDITOR", description: "Read-only access" }
            ],
            verified: false,
            active: true,
            lastLoginAt: ISODate("2024-10-04T09:30:00Z"),
            createdAt: ISODate("2024-10-03T00:00:00Z"),
            updatedAt: ISODate("2024-10-04T09:30:00Z")
        }
    },
    { upsert: true }
);

print("✅ Test data for Merchant, Tenant, and User inserted successfully!");
