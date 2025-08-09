// Switch to 'master' DB
db = db.getSiblingDB('master');

// Ensure collection exists
if (!db.getCollectionNames().includes('Tenant')) {
    db.createCollection('Tenant');
}

// Insert or upsert documents
db.Tenant.updateOne(
    { _id: ObjectId("67171f54dcbd9e7e9a52768f") },
    { $set: { name: "TOne" } },
    { upsert: true }
);

db.Tenant.updateOne(
    { _id: ObjectId("67171f8adcbd9e7e9a527690") },
    { $set: { name: "TTwo" } },
    { upsert: true }
);

db.Tenant.updateOne(
    { _id: ObjectId("687ee8c4fcbb23ffa95b4ad3") },
    { $set: { name: "Test" } },
    { upsert: true }
);
