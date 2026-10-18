// MongoDB Atlas Configuration
const mongoose = require('mongoose');

const MONGODB_ATLAS_URI = process.env.MONGODB_ATLAS_URI;

// MongoDB Atlas connection options
const mongoOptions = {
    useNewUrlParser: true,
    useUnifiedTopology: true,
    retryWrites: true,
    w: 'majority'
};

// Connect to MongoDB Atlas
async function connectToMongoDB() {
    if (!MONGODB_ATLAS_URI) {
        console.error('❌ MONGODB_ATLAS_URI is not set');
        process.exit(1);
    }
    try {
        await mongoose.connect(MONGODB_ATLAS_URI, mongoOptions);
        console.log('✅ Connected to MongoDB Atlas');
    } catch (error) {
        console.error('❌ MongoDB Atlas connection error:', error);
        process.exit(1);
    }
}

// Handle connection events
mongoose.connection.on('connected', () => {
    console.log('MongoDB Atlas connected');
});

mongoose.connection.on('error', (err) => {
    console.error('MongoDB Atlas connection error:', err);
});

mongoose.connection.on('disconnected', () => {
    console.log('MongoDB Atlas disconnected');
});

module.exports = {
    connectToMongoDB,
    MONGODB_ATLAS_URI,
    mongoOptions
};
