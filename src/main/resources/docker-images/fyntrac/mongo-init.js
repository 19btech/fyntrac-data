// Create a new collection and insert data into it
db = db.getSiblingDB('master');  // Switch to the 'master' database
db.createCollection('Tenant');  // Create a collection named 'Tenant'

// Insert data into the 'Tenant' collection with specified _id values
db.Tenant.insertMany([
  {
    _id: ObjectId("67171f54dcbd9e7e9a52768f"),
    name: "TOne"
  },
  {
    _id: ObjectId("67171f8adcbd9e7e9a527690"),
    name: "TTwo"
  }
]);
