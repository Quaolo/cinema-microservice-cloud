// MongoDB Atlas Configuration
const mongoose = require('mongoose');

const MONGODB_ATLAS_URI = 'mongodb+srv://quaolo_db_user:SP8c5btN0AEL9HcP@cluster-cinema.gctahhz.mongodb.net/sample_mflix?retryWrites=true&w=majority&appName=Cluster-cinema';

// MongoDB Atlas connection options
const mongoOptions = {
    useNewUrlParser: true,
    useUnifiedTopology: true,
    retryWrites: true,
    w: 'majority'
};

// Connect to MongoDB Atlas
async function connectToMongoDB() {
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
