// Sample data for the local stack (runs once, on the first start of the mongo container).
// Movie ids 1-5 match the poster files in s3/posters.
const thisYear = new Date().getFullYear()

db.movies.insertMany([
  { id: 1, title: 'Midnight Express Line', year: thisYear, genres: ['Thriller'], runtime: 112, plot: 'A night train, five strangers and one missing ticket.' },
  { id: 2, title: 'The Glass Orchard', year: thisYear - 1, genres: ['Drama'], runtime: 98, plot: 'Two sisters inherit a greenhouse that hides an old secret.' },
  { id: 3, title: 'Orbit of Silence', year: thisYear - 3, genres: ['Sci-Fi'], runtime: 124, plot: 'A lone engineer keeps a dying space station alive.' },
  { id: 4, title: 'Harbor Lights', year: thisYear - 5, genres: ['Romance', 'Comedy'], runtime: 101, plot: 'A fisherman and a tourist share one unforgettable summer.' },
  { id: 5, title: 'One Week', year: 1920, genres: ['Comedy', 'Short'], runtime: 19, plot: 'Newlyweds build a kit house in one week, with chaotic results.' }
])

db.cinemas.insertMany([
  { cityId: 'catania', name: 'Cinema Odeon', rooms: 3 },
  { cityId: 'catania', name: 'Multisala Lux', rooms: 6 },
  { cityId: 'palermo', name: 'Cinema Rouge et Noir', rooms: 2 }
])
