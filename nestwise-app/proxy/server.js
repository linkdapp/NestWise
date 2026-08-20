// =============================================================================
// NestWise Mongo proxy — server.js
// Thin, read-mostly REST proxy fronting MongoDB for APEX REST Data Sources.
// Five GET endpoints + one guarded admin POST. No ORM, no business logic
// beyond "run this query, shape this JSON" — see docs/architecture.md for
// why this exists instead of pulling Mongo into PL/SQL or the (unsupported,
// on Oracle 12c R2) ORDS-native MongoDB API.
//
// Run with:  NESTWISE_MONGO_URL=mongodb://mongo-host:27017 \
//            NESTWISE_ADMIN_TOKEN=<pick-a-secret> \
//            npm start
// Listens on port 4000 by default (see docs/install.md).
// =============================================================================
const express = require('express');
const app = express();
app.use(express.json());

app.use('/api/listings', require('./routes/listings'));
app.use('/api/movies',   require('./routes/movies'));
app.use('/api/weather',  require('./routes/weather'));
app.use('/api/admin',    require('./routes/admin'));

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'nestwise-mongo-proxy' }));

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
    console.log(`[nestwise-proxy] listening on port ${PORT}`);
});
