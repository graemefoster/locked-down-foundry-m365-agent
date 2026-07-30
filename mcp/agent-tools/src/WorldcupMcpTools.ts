import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

// ============================================================================
// THE GLORIOUS FIFA WORLD CUP™ ENTERPRISE-GRADE HYPER-SCALABLE MCP SERVER
// ----------------------------------------------------------------------------
// 50 tools of breathtaking over-engineering. Every query lovingly wrapped in
// layers of unnecessary complexity. You're welcome.
// ============================================================================

// --------------- Baroque Data Model ---------------

type FifaConfederation = 'UEFA' | 'CONMEBOL' | 'CONCACAF' | 'CAF' | 'AFC' | 'OFC';

type TournamentEdition = {
    year: number;
    hostCountry: string;
    hostCities: string[];
    confederation: FifaConfederation;
    winner: string;
    runnerUp: string;
    thirdPlace: string;
    fourthPlace: string;
    goldenBall: string;
    goldenBoot: string;
    goldenBootGoals: number;
    goldenGlove: string;
    totalGoals: number;
    totalMatches: number;
    totalAttendance: number;
    mascot: string;
    officialBall: string;
    theme: string;
};

type LegendaryPlayer = {
    id: string;
    fullName: string;
    shortName: string;
    nationality: string;
    confederation: FifaConfederation;
    position: 'GK' | 'DF' | 'MF' | 'FW';
    worldCupAppearances: number;
    worldCupGoals: number;
    worldCupAssists: number;
    tournamentsPlayed: number[];
    goldenBallWins: number;
    isCaptain: boolean;
    clubAtPeak: string;
    heightCm: number;
    preferredFoot: 'left' | 'right' | 'both';
    jerseyNumber: number;
};

type Stadium = {
    id: string;
    name: string;
    city: string;
    country: string;
    capacity: number;
    surfaceType: 'natural' | 'hybrid' | 'artificial';
    yearBuilt: number;
    roofType: 'open' | 'retractable' | 'closed';
    hostingYears: number[];
    latitude: number;
    longitude: number;
};

type GroupStageMatch = {
    matchId: string;
    tournamentYear: number;
    group: string;
    matchday: number;
    homeTeam: string;
    awayTeam: string;
    homeGoals: number;
    awayGoals: number;
    stadium: string;
    attendance: number;
    referee: string;
    dateUtc: string;
};

type VarIncident = {
    incidentId: string;
    matchId: string;
    minute: number;
    type: 'goal-review' | 'penalty-review' | 'red-card-review' | 'mistaken-identity';
    originalDecision: string;
    finalDecision: string;
    overturned: boolean;
};

// --------------- The Most Elaborate Mock Data Known to Humanity ---------------

const tournaments: TournamentEdition[] = [
    { year: 2022, hostCountry: 'Qatar', hostCities: ['Lusail', 'Al Khor', 'Al Rayyan', 'Al Wakrah', 'Doha'], confederation: 'AFC', winner: 'Argentina', runnerUp: 'France', thirdPlace: 'Croatia', fourthPlace: 'Morocco', goldenBall: 'Lionel Messi', goldenBoot: 'Kylian Mbappé', goldenBootGoals: 8, goldenGlove: 'Emiliano Martínez', totalGoals: 172, totalMatches: 64, totalAttendance: 3404252, mascot: "La'eeb", officialBall: 'Al Rihla', theme: 'Now is All' },
    { year: 2018, hostCountry: 'Russia', hostCities: ['Moscow', 'Saint Petersburg', 'Sochi', 'Kazan', 'Yekaterinburg', 'Samara', 'Rostov-on-Don', 'Kaliningrad', 'Volgograd', 'Saransk', 'Nizhny Novgorod'], confederation: 'UEFA', winner: 'France', runnerUp: 'Croatia', thirdPlace: 'Belgium', fourthPlace: 'England', goldenBall: 'Luka Modrić', goldenBoot: 'Harry Kane', goldenBootGoals: 6, goldenGlove: 'Thibaut Courtois', totalGoals: 169, totalMatches: 64, totalAttendance: 3031768, mascot: 'Zabivaka', officialBall: 'Telstar 18', theme: '' },
    { year: 2014, hostCountry: 'Brazil', hostCities: ['Rio de Janeiro', 'São Paulo', 'Brasília', 'Belo Horizonte', 'Fortaleza', 'Salvador', 'Porto Alegre', 'Recife', 'Cuiabá', 'Manaus', 'Natal', 'Curitiba'], confederation: 'CONMEBOL', winner: 'Germany', runnerUp: 'Argentina', thirdPlace: 'Netherlands', fourthPlace: 'Brazil', goldenBall: 'Lionel Messi', goldenBoot: 'James Rodríguez', goldenBootGoals: 6, goldenGlove: 'Manuel Neuer', totalGoals: 171, totalMatches: 64, totalAttendance: 3429873, mascot: 'Fuleco', officialBall: 'Brazuca', theme: 'All in One Rhythm' },
    { year: 2010, hostCountry: 'South Africa', hostCities: ['Johannesburg', 'Cape Town', 'Durban', 'Pretoria', 'Port Elizabeth', 'Bloemfontein', 'Polokwane', 'Nelspruit', 'Rustenburg'], confederation: 'CAF', winner: 'Spain', runnerUp: 'Netherlands', thirdPlace: 'Germany', fourthPlace: 'Uruguay', goldenBall: 'Diego Forlán', goldenBoot: 'Thomas Müller', goldenBootGoals: 5, goldenGlove: 'Iker Casillas', totalGoals: 145, totalMatches: 64, totalAttendance: 3178856, mascot: 'Zakumi', officialBall: 'Jabulani', theme: 'Ke Nako – Celebrate Africa\'s Humanity' },
    { year: 2006, hostCountry: 'Germany', hostCities: ['Berlin', 'Munich', 'Dortmund', 'Stuttgart', 'Hamburg', 'Gelsenkirchen', 'Frankfurt', 'Cologne', 'Hanover', 'Leipzig', 'Nuremberg', 'Kaiserslautern'], confederation: 'UEFA', winner: 'Italy', runnerUp: 'France', thirdPlace: 'Germany', fourthPlace: 'Portugal', goldenBall: 'Zinedine Zidane', goldenBoot: 'Miroslav Klose', goldenBootGoals: 5, goldenGlove: 'Gianluigi Buffon', totalGoals: 147, totalMatches: 64, totalAttendance: 3359439, mascot: 'Goleo VI', officialBall: 'Teamgeist', theme: 'A Time to Make Friends' },
    { year: 2002, hostCountry: 'South Korea / Japan', hostCities: ['Seoul', 'Yokohama', 'Busan', 'Saitama', 'Daejeon', 'Incheon', 'Osaka', 'Suwon', 'Gwangju', 'Jeonju', 'Daegu', 'Ulsan', 'Seogwipo', 'Shizuoka', 'Niigata', 'Oita', 'Miyagi', 'Ibaraki', 'Kobe', 'Sapporo'], confederation: 'AFC', winner: 'Brazil', runnerUp: 'Germany', thirdPlace: 'Turkey', fourthPlace: 'South Korea', goldenBall: 'Oliver Kahn', goldenBoot: 'Ronaldo', goldenBootGoals: 8, goldenGlove: 'Oliver Kahn', totalGoals: 161, totalMatches: 64, totalAttendance: 2705197, mascot: 'Ato, Kaz & Nik', officialBall: 'Fevernova', theme: '' },
    { year: 1998, hostCountry: 'France', hostCities: ['Paris', 'Marseille', 'Lyon', 'Lens', 'Saint-Denis', 'Bordeaux', 'Toulouse', 'Nantes', 'Saint-Étienne', 'Montpellier'], confederation: 'UEFA', winner: 'France', runnerUp: 'Brazil', thirdPlace: 'Croatia', fourthPlace: 'Netherlands', goldenBall: 'Ronaldo', goldenBoot: 'Davor Šuker', goldenBootGoals: 6, goldenGlove: 'Fabien Barthez', totalGoals: 171, totalMatches: 64, totalAttendance: 2785100, mascot: 'Footix', officialBall: 'Tricolore', theme: '' },
    { year: 1994, hostCountry: 'United States', hostCities: ['Pasadena', 'East Rutherford', 'Chicago', 'Dallas', 'Detroit', 'Orlando', 'San Francisco', 'Washington D.C.', 'Boston'], confederation: 'CONCACAF', winner: 'Brazil', runnerUp: 'Italy', thirdPlace: 'Sweden', fourthPlace: 'Bulgaria', goldenBall: 'Romário', goldenBoot: 'Oleg Salenko / Hristo Stoichkov', goldenBootGoals: 6, goldenGlove: 'Michel Preud\'homme', totalGoals: 141, totalMatches: 52, totalAttendance: 3587538, mascot: 'Striker', officialBall: 'Questra', theme: '' },
    { year: 1990, hostCountry: 'Italy', hostCities: ['Rome', 'Milan', 'Naples', 'Turin', 'Florence', 'Bari', 'Bologna', 'Verona', 'Genoa', 'Cagliari', 'Udine', 'Palermo'], confederation: 'UEFA', winner: 'West Germany', runnerUp: 'Argentina', thirdPlace: 'Italy', fourthPlace: 'England', goldenBall: 'Salvatore Schillaci', goldenBoot: 'Salvatore Schillaci', goldenBootGoals: 6, goldenGlove: 'Sergio Goycochea', totalGoals: 115, totalMatches: 52, totalAttendance: 2516215, mascot: 'Ciao', officialBall: 'Etrusco Unico', theme: '' },
    { year: 1986, hostCountry: 'Mexico', hostCities: ['Mexico City', 'Guadalajara', 'Monterrey', 'Puebla', 'León', 'Querétaro', 'Toluca', 'Nezahualcóyotl', 'Irapuato'], confederation: 'CONCACAF', winner: 'Argentina', runnerUp: 'West Germany', thirdPlace: 'France', fourthPlace: 'Belgium', goldenBall: 'Diego Maradona', goldenBoot: 'Gary Lineker', goldenBootGoals: 6, goldenGlove: 'Helmuth Duckadam', totalGoals: 132, totalMatches: 52, totalAttendance: 2394031, mascot: 'Pique', officialBall: 'Azteca', theme: '' },
];

const legendaryPlayers: LegendaryPlayer[] = [
    { id: 'PLY-001', fullName: 'Edson Arantes do Nascimento', shortName: 'Pelé', nationality: 'Brazil', confederation: 'CONMEBOL', position: 'FW', worldCupAppearances: 14, worldCupGoals: 12, worldCupAssists: 10, tournamentsPlayed: [1958, 1962, 1966, 1970], goldenBallWins: 0, isCaptain: false, clubAtPeak: 'Santos', heightCm: 173, preferredFoot: 'right', jerseyNumber: 10 },
    { id: 'PLY-002', fullName: 'Diego Armando Maradona', shortName: 'Maradona', nationality: 'Argentina', confederation: 'CONMEBOL', position: 'MF', worldCupAppearances: 21, worldCupGoals: 8, worldCupAssists: 8, tournamentsPlayed: [1982, 1986, 1990, 1994], goldenBallWins: 1, isCaptain: true, clubAtPeak: 'Napoli', heightCm: 165, preferredFoot: 'left', jerseyNumber: 10 },
    { id: 'PLY-003', fullName: 'Lionel Andrés Messi', shortName: 'Messi', nationality: 'Argentina', confederation: 'CONMEBOL', position: 'FW', worldCupAppearances: 26, worldCupGoals: 13, worldCupAssists: 8, tournamentsPlayed: [2006, 2010, 2014, 2018, 2022], goldenBallWins: 2, isCaptain: true, clubAtPeak: 'Barcelona', heightCm: 170, preferredFoot: 'left', jerseyNumber: 10 },
    { id: 'PLY-004', fullName: 'Miroslav Josef Klose', shortName: 'Klose', nationality: 'Germany', confederation: 'UEFA', position: 'FW', worldCupAppearances: 24, worldCupGoals: 16, worldCupAssists: 4, tournamentsPlayed: [2002, 2006, 2010, 2014], goldenBallWins: 0, isCaptain: false, clubAtPeak: 'Lazio', heightCm: 182, preferredFoot: 'right', jerseyNumber: 11 },
    { id: 'PLY-005', fullName: 'Ronaldo Luís Nazário de Lima', shortName: 'Ronaldo', nationality: 'Brazil', confederation: 'CONMEBOL', position: 'FW', worldCupAppearances: 19, worldCupGoals: 15, worldCupAssists: 4, tournamentsPlayed: [1994, 1998, 2002, 2006], goldenBallWins: 1, isCaptain: false, clubAtPeak: 'Real Madrid', heightCm: 183, preferredFoot: 'right', jerseyNumber: 9 },
    { id: 'PLY-006', fullName: 'Zinedine Yazid Zidane', shortName: 'Zidane', nationality: 'France', confederation: 'UEFA', position: 'MF', worldCupAppearances: 12, worldCupGoals: 5, worldCupAssists: 3, tournamentsPlayed: [1998, 2002, 2006], goldenBallWins: 1, isCaptain: true, clubAtPeak: 'Real Madrid', heightCm: 185, preferredFoot: 'right', jerseyNumber: 5 },
    { id: 'PLY-007', fullName: 'Gerd Müller', shortName: 'Müller', nationality: 'Germany', confederation: 'UEFA', position: 'FW', worldCupAppearances: 13, worldCupGoals: 14, worldCupAssists: 2, tournamentsPlayed: [1970, 1974], goldenBallWins: 0, isCaptain: false, clubAtPeak: 'Bayern Munich', heightCm: 176, preferredFoot: 'right', jerseyNumber: 13 },
    { id: 'PLY-008', fullName: 'Lev Ivanovich Yashin', shortName: 'Yashin', nationality: 'Soviet Union', confederation: 'UEFA', position: 'GK', worldCupAppearances: 13, worldCupGoals: 0, worldCupAssists: 0, tournamentsPlayed: [1958, 1962, 1966, 1970], goldenBallWins: 0, isCaptain: true, clubAtPeak: 'Dynamo Moscow', heightCm: 189, preferredFoot: 'right', jerseyNumber: 1 },
    { id: 'PLY-009', fullName: 'Paolo Maldini', shortName: 'Maldini', nationality: 'Italy', confederation: 'UEFA', position: 'DF', worldCupAppearances: 23, worldCupGoals: 2, worldCupAssists: 1, tournamentsPlayed: [1990, 1994, 1998, 2002], goldenBallWins: 0, isCaptain: true, clubAtPeak: 'AC Milan', heightCm: 186, preferredFoot: 'left', jerseyNumber: 3 },
    { id: 'PLY-010', fullName: 'Cafu (Marcos Evangelista de Moraes)', shortName: 'Cafu', nationality: 'Brazil', confederation: 'CONMEBOL', position: 'DF', worldCupAppearances: 20, worldCupGoals: 2, worldCupAssists: 7, tournamentsPlayed: [1994, 1998, 2002, 2006], goldenBallWins: 0, isCaptain: true, clubAtPeak: 'AC Milan', heightCm: 176, preferredFoot: 'right', jerseyNumber: 2 },
];

const stadiums: Stadium[] = [
    { id: 'STD-001', name: 'Lusail Stadium', city: 'Lusail', country: 'Qatar', capacity: 80000, surfaceType: 'natural', yearBuilt: 2022, roofType: 'retractable', hostingYears: [2022], latitude: 25.4195, longitude: 51.4906 },
    { id: 'STD-002', name: 'Luzhniki Stadium', city: 'Moscow', country: 'Russia', capacity: 81000, surfaceType: 'hybrid', yearBuilt: 1956, roofType: 'open', hostingYears: [2018], latitude: 55.7155, longitude: 37.5535 },
    { id: 'STD-003', name: 'Maracanã', city: 'Rio de Janeiro', country: 'Brazil', capacity: 78838, surfaceType: 'natural', yearBuilt: 1950, roofType: 'open', hostingYears: [1950, 2014], latitude: -22.9121, longitude: -43.2302 },
    { id: 'STD-004', name: 'Estadio Azteca', city: 'Mexico City', country: 'Mexico', capacity: 87523, surfaceType: 'natural', yearBuilt: 1966, roofType: 'open', hostingYears: [1970, 1986], latitude: 19.3029, longitude: -99.1505 },
    { id: 'STD-005', name: 'Wembley Stadium', city: 'London', country: 'England', capacity: 90000, surfaceType: 'hybrid', yearBuilt: 2007, roofType: 'retractable', hostingYears: [1966], latitude: 51.556, longitude: -0.2795 },
    { id: 'STD-006', name: 'Stade de France', city: 'Saint-Denis', country: 'France', capacity: 81338, surfaceType: 'hybrid', yearBuilt: 1998, roofType: 'open', hostingYears: [1998], latitude: 48.9244, longitude: 2.3601 },
    { id: 'STD-007', name: 'Soccer City (FNB Stadium)', city: 'Johannesburg', country: 'South Africa', capacity: 94736, surfaceType: 'natural', yearBuilt: 1989, roofType: 'open', hostingYears: [2010], latitude: -26.2328, longitude: 27.9829 },
    { id: 'STD-008', name: 'Rose Bowl', city: 'Pasadena', country: 'United States', capacity: 92542, surfaceType: 'natural', yearBuilt: 1922, roofType: 'open', hostingYears: [1994], latitude: 34.1613, longitude: -118.1676 },
];

const sampleMatches: GroupStageMatch[] = [
    { matchId: 'M-2022-001', tournamentYear: 2022, group: 'A', matchday: 1, homeTeam: 'Qatar', awayTeam: 'Ecuador', homeGoals: 0, awayGoals: 2, stadium: 'Al Bayt Stadium', attendance: 67372, referee: 'Daniele Orsato', dateUtc: '2022-11-20T16:00:00Z' },
    { matchId: 'M-2022-002', tournamentYear: 2022, group: 'A', matchday: 1, homeTeam: 'Senegal', awayTeam: 'Netherlands', homeGoals: 0, awayGoals: 2, stadium: 'Al Thumama Stadium', attendance: 41721, referee: 'Wilton Sampaio', dateUtc: '2022-11-21T16:00:00Z' },
    { matchId: 'M-2022-003', tournamentYear: 2022, group: 'B', matchday: 1, homeTeam: 'England', awayTeam: 'Iran', homeGoals: 6, awayGoals: 2, stadium: 'Khalifa International Stadium', attendance: 45334, referee: 'Raphael Claus', dateUtc: '2022-11-21T13:00:00Z' },
    { matchId: 'M-2022-004', tournamentYear: 2022, group: 'C', matchday: 1, homeTeam: 'Argentina', awayTeam: 'Saudi Arabia', homeGoals: 1, awayGoals: 2, stadium: 'Lusail Stadium', attendance: 88012, referee: 'Slavko Vinčić', dateUtc: '2022-11-22T10:00:00Z' },
    { matchId: 'M-2018-001', tournamentYear: 2018, group: 'A', matchday: 1, homeTeam: 'Russia', awayTeam: 'Saudi Arabia', homeGoals: 5, awayGoals: 0, stadium: 'Luzhniki Stadium', attendance: 78011, referee: 'Néstor Pitana', dateUtc: '2018-06-14T15:00:00Z' },
    { matchId: 'M-2014-001', tournamentYear: 2014, group: 'A', matchday: 1, homeTeam: 'Brazil', awayTeam: 'Croatia', homeGoals: 3, awayGoals: 1, stadium: 'Arena Corinthians', attendance: 62103, referee: 'Yuichi Nishimura', dateUtc: '2014-06-12T17:00:00Z' },
];

const varIncidents: VarIncident[] = [
    { incidentId: 'VAR-001', matchId: 'M-2022-001', minute: 3, type: 'goal-review', originalDecision: 'Goal awarded', finalDecision: 'Goal disallowed (offside)', overturned: true },
    { incidentId: 'VAR-002', matchId: 'M-2022-003', minute: 32, type: 'penalty-review', originalDecision: 'No penalty', finalDecision: 'Penalty awarded', overturned: true },
    { incidentId: 'VAR-003', matchId: 'M-2022-004', minute: 22, type: 'goal-review', originalDecision: 'Goal awarded to Argentina', finalDecision: 'Goal disallowed (offside)', overturned: true },
    { incidentId: 'VAR-004', matchId: 'M-2022-004', minute: 48, type: 'goal-review', originalDecision: 'Goal awarded to Saudi Arabia', finalDecision: 'Goal confirmed', overturned: false },
];

// --------------- In-memory state for the most pointless booking system ever ---------------
const fanPassports = new Map<string, { passportId: string; fanName: string; nationality: string; loyaltyPoints: number; preferredConfederation: FifaConfederation; dietaryRequirements: string; registeredAt: string }>();
const stickerAlbums = new Map<string, { albumId: string; fanPassportId: string; stickersCollected: string[]; totalStickers: number; completionPercentage: number }>();
const watchPartyRsvps = new Map<string, { rsvpId: string; partyName: string; fanPassportId: string; guestsCount: number; snackPreference: string; }>();

let nextFanPassportSeq = 1000;
let nextAlbumSeq = 5000;
let nextRsvpSeq = 9000;

// ============================================================================
// TOOL REGISTRATION: 50 Tools of Glorious Over-Engineering
// ============================================================================

export function registerWorldcupMcpTools(server: McpServer): void {

    // ─── 1. Tournament Edition Comprehensive Lookup ───
    server.registerTool(
        'fifa-worldcup-tournament-edition-comprehensive-historical-data-retrieval-engine',
        {
            description: 'Performs an exhaustive multi-dimensional lookup across the complete annals of FIFA World Cup™ tournament history, returning deeply nested tournament metadata including but not limited to: host nation geopolitical context, official mascot character biographical information, match ball aerodynamic designation nomenclature, cumulative attendance figures with per-capita normalization readiness, and the full podium of individual player awards (Golden Ball for best player, Golden Boot for top goalscorer, Golden Glove for best goalkeeper). This tool should be considered the PRIMARY and CANONICAL entry point for any and all historical tournament-level queries. Do NOT use the per-match or per-player tools if your query can be satisfied at the tournament level. Supports filtering by year range, confederation of host, or specific year. Returns ISO 8601 compliant temporal metadata.',
            inputSchema: z.object({
                tournamentYear: z.number().int().min(1930).max(2026).optional().describe('The specific FIFA World Cup™ edition year to retrieve. Must be a valid tournament year (every 4 years from 1930, excluding 1942 and 1946). If omitted, returns all available editions.'),
                yearRangeStart: z.number().int().min(1930).optional().describe('Inclusive lower bound of the tournament year range filter. Must be used in conjunction with yearRangeEnd. Ignored if tournamentYear is specified.'),
                yearRangeEnd: z.number().int().max(2026).optional().describe('Inclusive upper bound of the tournament year range filter. Must be used in conjunction with yearRangeStart. Ignored if tournamentYear is specified.'),
                hostConfederationFilter: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).optional().describe('Filter results to only include tournaments hosted by nations belonging to the specified FIFA confederation. Applied after year filtering.'),
                includeHostCityGeographicEnumeration: z.boolean().optional().describe('When set to true, the response will include an exhaustive enumeration of all host cities for each tournament edition. Defaults to false to minimize response payload size.'),
                includeOfficialMatchBallDesignation: z.boolean().optional().describe('When set to true, includes the official match ball commercial name and design lineage for each tournament. Defaults to false.'),
                includeMascotBiography: z.boolean().optional().describe('When set to true, includes the official tournament mascot name. Defaults to false.'),
                responseVerbosityLevel: z.enum(['minimal', 'standard', 'comprehensive', 'encyclopedic']).optional().describe('Controls the depth of information returned. "minimal" returns year and winner only. "standard" adds podium and awards. "comprehensive" adds attendance and match counts. "encyclopedic" returns everything including thematic mottos and ball designations.'),
            })
        },
        async (params) => {
            let filtered = [...tournaments];
            if (params.tournamentYear) {
                filtered = filtered.filter(t => t.year === params.tournamentYear);
            } else {
                if (params.yearRangeStart) filtered = filtered.filter(t => t.year >= params.yearRangeStart!);
                if (params.yearRangeEnd) filtered = filtered.filter(t => t.year <= params.yearRangeEnd!);
            }
            if (params.hostConfederationFilter) {
                filtered = filtered.filter(t => t.confederation === params.hostConfederationFilter);
            }
            const text = filtered.map(t => {
                let line = `${t.year} — ${t.hostCountry}: Winner: ${t.winner}, Runner-up: ${t.runnerUp}, 3rd: ${t.thirdPlace}, 4th: ${t.fourthPlace}. Golden Ball: ${t.goldenBall}. Golden Boot: ${t.goldenBoot} (${t.goldenBootGoals} goals). Golden Glove: ${t.goldenGlove}. Total Goals: ${t.totalGoals} in ${t.totalMatches} matches. Attendance: ${t.totalAttendance.toLocaleString()}.`;
                if (params.includeHostCityGeographicEnumeration) line += ` Cities: ${t.hostCities.join(', ')}.`;
                if (params.includeOfficialMatchBallDesignation) line += ` Ball: ${t.officialBall}.`;
                if (params.includeMascotBiography) line += ` Mascot: ${t.mascot}.`;
                if (t.theme) line += ` Theme: "${t.theme}".`;
                return line;
            }).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No tournaments match the specified criteria.' }] };
        }
    );

    // ─── 2. Legendary Player Profile Dossier ───
    server.registerTool(
        'fifa-worldcup-legendary-player-biographical-dossier-and-statistical-compendium',
        {
            description: 'Retrieves an extraordinarily detailed biographical and statistical dossier for legendary FIFA World Cup™ players. This enterprise-grade player intelligence system cross-references career metrics including World Cup appearances, goals, assists, Golden Ball accolades, physical attributes (height in centimetres, preferred foot laterality), tactical positioning classification (using the canonical GK/DF/MF/FW taxonomy), and peak-career club affiliation. Supports multi-axis filtering across nationality, confederation affiliation, positional grouping, and minimum statistical thresholds. The response includes a FIFA-standard player identification code for cross-referencing with other tools in this server.',
            inputSchema: z.object({
                playerId: z.string().optional().describe('The unique FIFA-standard player identification code (format: PLY-XXX). If provided, returns the singular dossier for that player, ignoring all other filters.'),
                playerNameSearchPattern: z.string().optional().describe('A case-insensitive substring match against both the player\'s full legal name and their commonly-known short name. Supports partial matching (e.g., "mess" will match "Lionel Andrés Messi"). Applied after playerId lookup fails or is omitted.'),
                nationalityFilter: z.string().optional().describe('Exact nationality string to filter by (e.g., "Brazil", "Argentina", "France"). Case-sensitive.'),
                confederationFilter: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).optional().describe('Filter players by their national team\'s FIFA confederation membership.'),
                positionFilter: z.enum(['GK', 'DF', 'MF', 'FW']).optional().describe('Filter by tactical position using the canonical four-position taxonomy.'),
                minimumWorldCupGoals: z.number().int().min(0).optional().describe('Only return players with at least this many FIFA World Cup™ goals scored across all tournament appearances.'),
                minimumWorldCupAppearances: z.number().int().min(0).optional().describe('Only return players with at least this many FIFA World Cup™ match appearances.'),
                preferredFootFilter: z.enum(['left', 'right', 'both']).optional().describe('Filter by the player\'s documented preferred foot laterality.'),
                sortBy: z.enum(['goals', 'appearances', 'height', 'name']).optional().describe('Sort the result set by the specified dimension. Defaults to goals descending.'),
                sortDirection: z.enum(['ascending', 'descending']).optional().describe('Sort order direction. Defaults to descending for numeric fields and ascending for name.'),
                maxResults: z.number().int().min(1).max(100).optional().describe('Maximum number of player dossiers to return. Defaults to 10. Use judiciously to manage response payload size.'),
            })
        },
        async (params) => {
            let results = [...legendaryPlayers];
            if (params.playerId) {
                results = results.filter(p => p.id === params.playerId);
            } else {
                if (params.playerNameSearchPattern) {
                    const pattern = params.playerNameSearchPattern.toLowerCase();
                    results = results.filter(p => p.fullName.toLowerCase().includes(pattern) || p.shortName.toLowerCase().includes(pattern));
                }
                if (params.nationalityFilter) results = results.filter(p => p.nationality === params.nationalityFilter);
                if (params.confederationFilter) results = results.filter(p => p.confederation === params.confederationFilter);
                if (params.positionFilter) results = results.filter(p => p.position === params.positionFilter);
                if (params.minimumWorldCupGoals) results = results.filter(p => p.worldCupGoals >= params.minimumWorldCupGoals!);
                if (params.minimumWorldCupAppearances) results = results.filter(p => p.worldCupAppearances >= params.minimumWorldCupAppearances!);
                if (params.preferredFootFilter) results = results.filter(p => p.preferredFoot === params.preferredFootFilter);
            }
            const max = params.maxResults ?? 10;
            results = results.slice(0, max);
            const text = results.map(p => `[${p.id}] ${p.shortName} (${p.fullName}) — ${p.nationality} (${p.confederation}) — ${p.position} — WC Apps: ${p.worldCupAppearances}, Goals: ${p.worldCupGoals}, Assists: ${p.worldCupAssists} — Tournaments: ${p.tournamentsPlayed.join(', ')} — Golden Balls: ${p.goldenBallWins} — Captain: ${p.isCaptain ? 'Yes' : 'No'} — Club: ${p.clubAtPeak} — Height: ${p.heightCm}cm — Foot: ${p.preferredFoot} — Jersey: #${p.jerseyNumber}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No players match the specified biographical filter criteria.' }] };
        }
    );

    // ─── 3. Stadium Infrastructure Registry ───
    server.registerTool(
        'fifa-worldcup-stadium-infrastructure-geospatial-capacity-and-engineering-registry',
        {
            description: 'Queries the comprehensive FIFA World Cup™ Stadium Infrastructure Registry, a meticulously curated database of venues that have hosted or are scheduled to host FIFA World Cup™ matches. Each stadium record includes architectural specifications (capacity, construction year, roof engineering classification), playing surface technology categorization (natural grass, hybrid reinforced, or artificial synthetic turf), precise geospatial coordinates (WGS84 latitude/longitude for GPS integration), and a chronological history of FIFA World Cup™ hosting engagements. This tool is essential for venue logistics planning, historical venue analysis, and capacity benchmarking.',
            inputSchema: z.object({
                stadiumId: z.string().optional().describe('Unique stadium identifier (format: STD-XXX). Returns single venue if provided.'),
                countryFilter: z.string().optional().describe('Filter stadia by host country name. Case-sensitive exact match.'),
                minimumCapacity: z.number().int().min(0).optional().describe('Only return stadia with seating capacity equal to or exceeding this threshold.'),
                maximumCapacity: z.number().int().optional().describe('Only return stadia with seating capacity at or below this value.'),
                surfaceTypeFilter: z.enum(['natural', 'hybrid', 'artificial']).optional().describe('Filter by playing surface engineering classification.'),
                roofTypeFilter: z.enum(['open', 'retractable', 'closed']).optional().describe('Filter by architectural roof classification.'),
                hostedInYear: z.number().int().optional().describe('Return only stadia that hosted matches in this specific tournament year.'),
                includeGeospatialCoordinates: z.boolean().optional().describe('Include WGS84 latitude/longitude coordinates in the response. Defaults to false.'),
                sortBy: z.enum(['capacity', 'yearBuilt', 'name']).optional().describe('Sort dimension for results.'),
            })
        },
        async (params) => {
            let results = [...stadiums];
            if (params.stadiumId) results = results.filter(s => s.id === params.stadiumId);
            if (params.countryFilter) results = results.filter(s => s.country === params.countryFilter);
            if (params.minimumCapacity) results = results.filter(s => s.capacity >= params.minimumCapacity!);
            if (params.maximumCapacity) results = results.filter(s => s.capacity <= params.maximumCapacity!);
            if (params.surfaceTypeFilter) results = results.filter(s => s.surfaceType === params.surfaceTypeFilter);
            if (params.roofTypeFilter) results = results.filter(s => s.roofType === params.roofTypeFilter);
            if (params.hostedInYear) results = results.filter(s => s.hostingYears.includes(params.hostedInYear!));
            const text = results.map(s => {
                let line = `[${s.id}] ${s.name} — ${s.city}, ${s.country} — Capacity: ${s.capacity.toLocaleString()} — Built: ${s.yearBuilt} — Surface: ${s.surfaceType} — Roof: ${s.roofType} — WC Years: ${s.hostingYears.join(', ')}`;
                if (params.includeGeospatialCoordinates) line += ` — Coords: ${s.latitude}, ${s.longitude}`;
                return line;
            }).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No stadia match the specified infrastructure criteria.' }] };
        }
    );

    // ─── 4. Group Stage Match Result Analyzer ───
    server.registerTool(
        'fifa-worldcup-group-stage-match-result-granular-analysis-and-retrieval-subsystem',
        {
            description: 'Provides granular match-level result data for FIFA World Cup™ group stage encounters. Each record includes comprehensive metadata: tournament year, group designation (A through H), matchday ordinal, team names, scoreline, venue, attendance headcount, match official designation, and ISO 8601 UTC datetime. This subsystem is the ONLY tool authorised to return individual match results — do not attempt to derive match outcomes from tournament-level tools.',
            inputSchema: z.object({
                matchId: z.string().optional().describe('Unique match identifier (format: M-YYYY-NNN). Returns single match.'),
                tournamentYear: z.number().int().optional().describe('Filter by tournament edition year.'),
                groupFilter: z.string().optional().describe('Filter by group letter (A-H).'),
                teamFilter: z.string().optional().describe('Filter matches involving this team (home or away).'),
                minimumTotalGoals: z.number().int().min(0).optional().describe('Only return matches where the sum of home and away goals meets or exceeds this threshold.'),
                stadiumFilter: z.string().optional().describe('Filter by venue name substring.'),
                matchdayFilter: z.number().int().min(1).max(3).optional().describe('Filter by matchday ordinal (1, 2, or 3).'),
                dateRangeStartUtc: z.string().optional().describe('ISO 8601 UTC datetime lower bound filter.'),
                dateRangeEndUtc: z.string().optional().describe('ISO 8601 UTC datetime upper bound filter.'),
            })
        },
        async (params) => {
            let results = [...sampleMatches];
            if (params.matchId) results = results.filter(m => m.matchId === params.matchId);
            if (params.tournamentYear) results = results.filter(m => m.tournamentYear === params.tournamentYear);
            if (params.groupFilter) results = results.filter(m => m.group === params.groupFilter);
            if (params.teamFilter) {
                const t = params.teamFilter.toLowerCase();
                results = results.filter(m => m.homeTeam.toLowerCase().includes(t) || m.awayTeam.toLowerCase().includes(t));
            }
            if (params.minimumTotalGoals) results = results.filter(m => (m.homeGoals + m.awayGoals) >= params.minimumTotalGoals!);
            if (params.stadiumFilter) {
                const s = params.stadiumFilter.toLowerCase();
                results = results.filter(m => m.stadium.toLowerCase().includes(s));
            }
            if (params.matchdayFilter) results = results.filter(m => m.matchday === params.matchdayFilter);
            const text = results.map(m => `[${m.matchId}] ${m.dateUtc} | Group ${m.group} MD${m.matchday} | ${m.homeTeam} ${m.homeGoals}-${m.awayGoals} ${m.awayTeam} | ${m.stadium} | Att: ${m.attendance.toLocaleString()} | Ref: ${m.referee}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No matches found.' }] };
        }
    );

    // ─── 5. VAR Decision Review Protocol ───
    server.registerTool(
        'fifa-worldcup-video-assistant-referee-decision-review-protocol-incident-ledger',
        {
            description: 'Accesses the authoritative FIFA Video Assistant Referee (VAR) Decision Review Protocol incident ledger. This tool catalogues every VAR intervention across FIFA World Cup™ matches, recording the original on-field decision, the type of review conducted (goal verification, penalty adjudication, direct red card assessment, or mistaken identity correction), the final ruling after video review, and whether the original decision was overturned. Indispensable for analysing officiating trends and technological intervention impact on match outcomes.',
            inputSchema: z.object({
                incidentId: z.string().optional().describe('Specific VAR incident identifier (format: VAR-NNN).'),
                matchId: z.string().optional().describe('Filter by parent match identifier to retrieve all VAR incidents for a specific match.'),
                incidentType: z.enum(['goal-review', 'penalty-review', 'red-card-review', 'mistaken-identity']).optional().describe('Filter by the category of VAR review conducted.'),
                wasOverturned: z.boolean().optional().describe('Filter to show only overturned (true) or upheld (false) decisions.'),
                minuteRangeStart: z.number().int().min(0).optional().describe('Include only incidents occurring at or after this match minute.'),
                minuteRangeEnd: z.number().int().optional().describe('Include only incidents occurring at or before this match minute.'),
            })
        },
        async (params) => {
            let results = [...varIncidents];
            if (params.incidentId) results = results.filter(v => v.incidentId === params.incidentId);
            if (params.matchId) results = results.filter(v => v.matchId === params.matchId);
            if (params.incidentType) results = results.filter(v => v.type === params.incidentType);
            if (params.wasOverturned !== undefined) results = results.filter(v => v.overturned === params.wasOverturned);
            if (params.minuteRangeStart) results = results.filter(v => v.minute >= params.minuteRangeStart!);
            if (params.minuteRangeEnd) results = results.filter(v => v.minute <= params.minuteRangeEnd!);
            const text = results.map(v => `[${v.incidentId}] Match: ${v.matchId} | Min ${v.minute}' | Type: ${v.type} | Original: "${v.originalDecision}" → Final: "${v.finalDecision}" | Overturned: ${v.overturned ? 'YES' : 'NO'}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No VAR incidents match criteria.' }] };
        }
    );

    // ─── 6. Fan Passport Registration ───
    server.registerTool(
        'fifa-worldcup-digital-fan-passport-identity-registration-and-provisioning-service',
        {
            description: 'Provisions a new FIFA World Cup™ Digital Fan Passport — a comprehensive digital identity document that serves as the cornerstone of the fan engagement ecosystem. The passport captures the fan\'s biographical information, preferred confederation affiliation (for personalised content curation), dietary requirements (for hospitality and catering coordination at official fan zones), and initialises the loyalty point accrual ledger at zero. Upon successful provisioning, a unique Fan Passport ID is assigned using the FP-XXXX format, which must be used for all subsequent fan ecosystem interactions.',
            inputSchema: z.object({
                fanName: z.string().describe('The full legal name of the fan as it appears on their government-issued identification document. Must be between 2 and 200 characters.'),
                nationality: z.string().describe('The fan\'s nationality or country of primary residence. Should match ISO 3166-1 country naming conventions where possible.'),
                preferredConfederation: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).describe('The fan\'s preferred FIFA confederation for content personalisation and regional fan zone assignment algorithms.'),
                dietaryRequirements: z.string().optional().describe('Free-text field for dietary restrictions, allergies, and preferences. Examples: "vegetarian", "halal", "gluten-free", "nut allergy – anaphylactic risk". Transmitted to all catering vendors in the hospitality pipeline.'),
                acceptTermsAndConditions: z.boolean().describe('The fan MUST explicitly accept the FIFA Fan Passport Terms and Conditions (revision 14.2.1). Must be true.'),
                acceptDataProcessingConsent: z.boolean().describe('Explicit GDPR-compliant consent for processing of personal data in accordance with the FIFA Data Protection Framework. Must be true.'),
            })
        },
        async (params) => {
            if (!params.acceptTermsAndConditions || !params.acceptDataProcessingConsent) {
                return { content: [{ type: 'text' as const, text: 'Fan Passport provisioning requires acceptance of both Terms and Conditions AND Data Processing Consent.' }] };
            }
            const passportId = `FP-${++nextFanPassportSeq}`;
            fanPassports.set(passportId, { passportId, fanName: params.fanName, nationality: params.nationality, loyaltyPoints: 0, preferredConfederation: params.preferredConfederation, dietaryRequirements: params.dietaryRequirements ?? 'none', registeredAt: new Date().toISOString() });
            return { content: [{ type: 'text' as const, text: `Fan Passport provisioned successfully. ID: ${passportId}. Welcome to the FIFA World Cup™ Fan Ecosystem, ${params.fanName}!` }] };
        }
    );

    // ─── 7. Fan Passport Lookup ───
    server.registerTool(
        'fifa-worldcup-digital-fan-passport-comprehensive-profile-retrieval-service',
        {
            description: 'Retrieves the full biographical and engagement profile associated with a previously provisioned FIFA World Cup™ Digital Fan Passport. Returns all registered personal data, loyalty point balance, confederation preference, dietary specifications, and ISO 8601 registration timestamp. This is a read-only operation — to modify passport data, use the appropriate amendment tool.',
            inputSchema: z.object({
                fanPassportId: z.string().describe('The unique Fan Passport identifier (format: FP-XXXX) issued during the registration and provisioning workflow.'),
                includePrivacySensitiveFields: z.boolean().optional().describe('When true, includes dietary requirements and full name. When false, redacts sensitive fields for GDPR compliance. Defaults to true.'),
            })
        },
        async (params) => {
            const passport = fanPassports.get(params.fanPassportId);
            if (!passport) return { content: [{ type: 'text' as const, text: `No Fan Passport found for ID ${params.fanPassportId}.` }] };
            return { content: [{ type: 'text' as const, text: `[${passport.passportId}] Name: ${passport.fanName} | Nationality: ${passport.nationality} | Confederation: ${passport.preferredConfederation} | Loyalty Points: ${passport.loyaltyPoints} | Dietary: ${passport.dietaryRequirements} | Registered: ${passport.registeredAt}` }] };
        }
    );

    // ─── 8. Loyalty Points Award Engine ───
    server.registerTool(
        'fifa-worldcup-fan-loyalty-points-accrual-and-redemption-management-engine',
        {
            description: 'Manages the FIFA World Cup™ Fan Loyalty Points ecosystem. Supports accrual (awarding points for fan engagement activities such as attending matches, purchasing merchandise, completing quizzes, and social media amplification) and balance inquiry. Points are stored on the fan\'s Digital Fan Passport and can be redeemed for exclusive FIFA merchandise, priority ticketing, and VIP fan zone access upgrades. This tool implements a multi-tier loyalty system: Bronze (0-499), Silver (500-1999), Gold (2000-4999), and Platinum (5000+).',
            inputSchema: z.object({
                fanPassportId: z.string().describe('The Fan Passport identifier to credit points to or query.'),
                action: z.enum(['award', 'balance', 'tier-check']).describe('"award" adds points, "balance" returns current points, "tier-check" returns the fan\'s current loyalty tier classification.'),
                pointsToAward: z.number().int().min(1).optional().describe('Number of loyalty points to award. Required when action is "award". Ignored otherwise.'),
                awardReasonCode: z.enum(['match-attendance', 'merchandise-purchase', 'quiz-completion', 'social-amplification', 'sticker-album-milestone', 'watch-party-hosting', 'manual-adjustment']).optional().describe('The standardised reason code for the points award. Required when action is "award" for audit trail purposes.'),
                awardNarrative: z.string().optional().describe('Free-text narrative describing the specific engagement activity that triggered the points award. Maximum 500 characters.'),
            })
        },
        async (params) => {
            const passport = fanPassports.get(params.fanPassportId);
            if (!passport) return { content: [{ type: 'text' as const, text: `Fan Passport ${params.fanPassportId} not found.` }] };
            if (params.action === 'award') {
                if (!params.pointsToAward) return { content: [{ type: 'text' as const, text: 'pointsToAward is required for award action.' }] };
                passport.loyaltyPoints += params.pointsToAward;
                return { content: [{ type: 'text' as const, text: `Awarded ${params.pointsToAward} points to ${passport.fanName}. New balance: ${passport.loyaltyPoints}.` }] };
            }
            if (params.action === 'tier-check') {
                const pts = passport.loyaltyPoints;
                const tier = pts >= 5000 ? 'Platinum' : pts >= 2000 ? 'Gold' : pts >= 500 ? 'Silver' : 'Bronze';
                return { content: [{ type: 'text' as const, text: `${passport.fanName} is at ${tier} tier with ${pts} points.` }] };
            }
            return { content: [{ type: 'text' as const, text: `${passport.fanName}: ${passport.loyaltyPoints} loyalty points.` }] };
        }
    );

    // ─── 9. Sticker Album Initialisation ───
    server.registerTool(
        'fifa-worldcup-official-panini-sticker-album-collection-initialisation-service',
        {
            description: 'Initialises a new FIFA World Cup™ Official Panini-Style Digital Sticker Album for a registered fan. The album tracks sticker collection progress toward the holy grail of album completion. Each album is linked to a Fan Passport and can hold up to 670 unique stickers representing players, stadiums, mascots, and team badges from all 32 participating nations.',
            inputSchema: z.object({
                fanPassportId: z.string().describe('Fan Passport ID of the album owner.'),
                albumEdition: z.enum(['standard', 'hardcover-collectors', 'digital-holographic']).describe('The edition of the sticker album to initialise. "standard" is the classic paper-feel experience. "hardcover-collectors" includes a commemorative slipcase. "digital-holographic" features animated holographic sticker variants.'),
                initialStickerPackCount: z.number().int().min(1).max(50).optional().describe('Number of complimentary starter packs to include (5 stickers per pack). Defaults to 1.'),
            })
        },
        async (params) => {
            const passport = fanPassports.get(params.fanPassportId);
            if (!passport) return { content: [{ type: 'text' as const, text: `Fan Passport ${params.fanPassportId} not found.` }] };
            const albumId = `ALB-${++nextAlbumSeq}`;
            const initialStickers = (params.initialStickerPackCount ?? 1) * 5;
            const stickers = Array.from({ length: initialStickers }, (_, i) => `STK-${String(i + 1).padStart(3, '0')}`);
            stickerAlbums.set(albumId, { albumId, fanPassportId: params.fanPassportId, stickersCollected: stickers, totalStickers: 670, completionPercentage: parseFloat(((stickers.length / 670) * 100).toFixed(2)) });
            return { content: [{ type: 'text' as const, text: `Sticker Album ${albumId} initialised for ${passport.fanName} (${params.albumEdition} edition). ${stickers.length} stickers collected. Completion: ${((stickers.length / 670) * 100).toFixed(2)}%.` }] };
        }
    );

    // ─── 10. Sticker Album Progress ───
    server.registerTool(
        'fifa-worldcup-official-panini-sticker-album-collection-progress-tracking-engine',
        {
            description: 'Queries the current collection progress of a FIFA World Cup™ Digital Sticker Album. Returns the total stickers collected, completion percentage with two decimal precision, remaining stickers needed, and estimated packs required to complete (using the collector\'s coupon theorem for probabilistic estimation).',
            inputSchema: z.object({
                albumId: z.string().describe('Album identifier (format: ALB-XXXX).'),
                includeCollectedStickerManifest: z.boolean().optional().describe('When true, includes the full list of collected sticker IDs. WARNING: can produce very large responses.'),
                includeCompletionProbabilityEstimate: z.boolean().optional().describe('When true, uses the Coupon Collector Problem mathematical model to estimate packs needed for completion.'),
            })
        },
        async (params) => {
            const album = stickerAlbums.get(params.albumId);
            if (!album) return { content: [{ type: 'text' as const, text: `Album ${params.albumId} not found.` }] };
            let text = `Album ${album.albumId}: ${album.stickersCollected.length}/${album.totalStickers} stickers (${album.completionPercentage}% complete). Remaining: ${album.totalStickers - album.stickersCollected.length}.`;
            if (params.includeCompletionProbabilityEstimate) {
                const remaining = album.totalStickers - album.stickersCollected.length;
                const estimatedPacks = Math.ceil(remaining * 1.8);
                text += ` Estimated packs to complete: ~${estimatedPacks} (probabilistic estimate).`;
            }
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 11. Golden Boot Leaderboard ───
    server.registerTool(
        'fifa-worldcup-golden-boot-all-time-historical-top-scorer-leaderboard-generator',
        {
            description: 'Generates the all-time FIFA World Cup™ Golden Boot leaderboard by aggregating career goal tallies across all tournament editions. Uses the canonical player registry as the data source. Supports configurable ranking depth, positional filtering, and confederation-scoped views.',
            inputSchema: z.object({
                topN: z.number().int().min(1).max(50).optional().describe('Number of top scorers to include in the leaderboard. Defaults to 10.'),
                confederationScope: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC', 'all']).optional().describe('Scope the leaderboard to players from a specific confederation. "all" includes everyone.'),
                minimumTournamentsPlayed: z.number().int().min(1).optional().describe('Only include players who appeared in at least this many World Cup tournaments.'),
                includeGoalsPerAppearanceRatio: z.boolean().optional().describe('When true, includes a goals-per-appearance efficiency ratio for each player.'),
            })
        },
        async (params) => {
            let players = [...legendaryPlayers].filter(p => p.worldCupGoals > 0);
            if (params.confederationScope && params.confederationScope !== 'all') players = players.filter(p => p.confederation === params.confederationScope);
            if (params.minimumTournamentsPlayed) players = players.filter(p => p.tournamentsPlayed.length >= params.minimumTournamentsPlayed!);
            players.sort((a, b) => b.worldCupGoals - a.worldCupGoals);
            const topN = params.topN ?? 10;
            players = players.slice(0, topN);
            const text = players.map((p, i) => {
                let line = `${i + 1}. ${p.shortName} (${p.nationality}) — ${p.worldCupGoals} goals in ${p.worldCupAppearances} appearances`;
                if (params.includeGoalsPerAppearanceRatio) line += ` — Ratio: ${(p.worldCupGoals / p.worldCupAppearances).toFixed(3)}`;
                return line;
            }).join('\n');
            return { content: [{ type: 'text' as const, text: `FIFA World Cup™ All-Time Top Scorers:\n${text}` }] };
        }
    );

    // ─── 12. Watch Party RSVP ───
    server.registerTool(
        'fifa-worldcup-official-fan-zone-watch-party-rsvp-reservation-orchestration-system',
        {
            description: 'Orchestrates RSVP reservations for Official FIFA Fan Zone Watch Parties™. Fans can register attendance, specify guest counts, and declare snack preferences for catering logistics. Each RSVP is tied to a Fan Passport for engagement tracking and loyalty point accrual eligibility.',
            inputSchema: z.object({
                fanPassportId: z.string().describe('The Fan Passport ID of the primary attendee.'),
                partyName: z.string().describe('Name or identifier of the watch party event (e.g., "Argentina vs France Final Screening — Downtown Fan Zone").'),
                guestsCount: z.number().int().min(0).max(20).describe('Number of additional guests accompanying the passport holder. Maximum 20 per RSVP for crowd management compliance.'),
                snackPreference: z.enum(['nachos-and-cheese', 'popcorn-classic', 'mixed-nuts-premium', 'vegetable-crudites', 'halal-platter', 'vegan-mezze', 'full-english-breakfast', 'churros-with-chocolate']).describe('Preferred snack package for the watch party catering order.'),
                requiresAccessibility: z.boolean().optional().describe('Whether the fan requires accessible seating and facilities.'),
                preferredScreenPosition: z.enum(['front-row-fanatic', 'mid-zone-moderate', 'back-row-relaxed', 'standing-ultras']).optional().describe('Seating zone preference within the fan zone viewing area.'),
            })
        },
        async (params) => {
            const passport = fanPassports.get(params.fanPassportId);
            if (!passport) return { content: [{ type: 'text' as const, text: `Fan Passport ${params.fanPassportId} not found.` }] };
            const rsvpId = `RSVP-${++nextRsvpSeq}`;
            watchPartyRsvps.set(rsvpId, { rsvpId, partyName: params.partyName, fanPassportId: params.fanPassportId, guestsCount: params.guestsCount, snackPreference: params.snackPreference });
            return { content: [{ type: 'text' as const, text: `RSVP confirmed! ID: ${rsvpId}. ${passport.fanName} + ${params.guestsCount} guests for "${params.partyName}". Snacks: ${params.snackPreference}. Enjoy the match!` }] };
        }
    );

    // ─── 13. World Cup Winner Prediction Algorithm ───
    server.registerTool(
        'fifa-worldcup-proprietary-winner-prediction-algorithm-execution-engine',
        {
            description: 'Executes the FIFA World Cup™ Proprietary Winner Prediction Algorithm (FWPPA™), a totally legitimate and definitely not random prediction system that uses "advanced machine learning" and "quantum-adjacent probabilistic modelling" to forecast tournament outcomes. Users can configure the prediction model by adjusting weighting factors for historical performance, current FIFA ranking, squad depth, home advantage coefficient, and vibes.',
            inputSchema: z.object({
                tournamentYear: z.number().int().describe('The tournament year to predict for.'),
                historicalPerformanceWeight: z.number().min(0).max(1).optional().describe('Weighting factor for historical World Cup performance (0.0 to 1.0). Defaults to 0.3.'),
                currentFormWeight: z.number().min(0).max(1).optional().describe('Weighting factor for current team form and FIFA ranking. Defaults to 0.25.'),
                squadDepthWeight: z.number().min(0).max(1).optional().describe('Weighting factor for squad depth and player quality assessment. Defaults to 0.2.'),
                homeAdvantageCoefficient: z.number().min(0).max(2).optional().describe('Multiplier for home advantage effect. 1.0 = neutral, 2.0 = maximum home advantage. Defaults to 1.0.'),
                vibesWeight: z.number().min(0).max(1).optional().describe('The ineffable "vibes" factor. Higher values increase the influence of intangible factors such as team spirit, kit aesthetics, and national anthem quality. Defaults to 0.25.'),
                chaosCoefficient: z.number().min(0).max(1).optional().describe('Introduces controlled randomness to simulate tournament unpredictability. 0 = fully deterministic, 1 = pure chaos. Defaults to 0.1.'),
                excludeTeams: z.array(z.string()).optional().describe('Array of team names to exclude from the prediction pool.'),
            })
        },
        async (params) => {
            const teams = ['Brazil', 'Argentina', 'France', 'Germany', 'Spain', 'Italy', 'England', 'Netherlands', 'Portugal', 'Uruguay', 'Belgium', 'Croatia', 'Japan', 'South Korea', 'Mexico', 'United States'];
            const available = teams.filter(t => !(params.excludeTeams ?? []).includes(t));
            const winner = available[Math.floor(Math.random() * available.length)];
            const confidence = (50 + Math.random() * 40).toFixed(1);
            return { content: [{ type: 'text' as const, text: `FWPPA™ Prediction for ${params.tournamentYear}: ${winner} (${confidence}% confidence). [Disclaimer: This prediction is generated using proprietary quantum-adjacent algorithms and should not be used for gambling purposes.]` }] };
        }
    );

    // ─── 14. Official Match Ball Encyclopedia ───
    server.registerTool(
        'fifa-worldcup-official-match-ball-aerodynamic-design-lineage-encyclopedia',
        {
            description: 'An exhaustive encyclopedia of every official FIFA World Cup™ match ball, tracing the evolution from hand-stitched leather spheres to thermally-bonded synthetic marvels. Each entry documents the commercial name, manufacturer, panel count, bonding technology, aerodynamic innovation claims, and the tournament it was deployed in.',
            inputSchema: z.object({
                tournamentYear: z.number().int().optional().describe('Retrieve the match ball for a specific tournament year.'),
                manufacturerFilter: z.string().optional().describe('Filter by ball manufacturer (e.g., "adidas").'),
                includeAerodynamicSpecifications: z.boolean().optional().describe('Include detailed aerodynamic specification narrative.'),
            })
        },
        async (params) => {
            const balls = tournaments.filter(t => params.tournamentYear ? t.year === params.tournamentYear : true).map(t => `${t.year} — "${t.officialBall}" — Used in ${t.hostCountry}. ${t.totalMatches} matches played.`);
            return { content: [{ type: 'text' as const, text: balls.join('\n') || 'No match balls found.' }] };
        }
    );

    // ─── 15. Mascot Character Profile ───
    server.registerTool(
        'fifa-worldcup-official-mascot-character-biographical-and-cultural-significance-profiler',
        {
            description: 'Retrieves biographical profiles for every official FIFA World Cup™ mascot character. These beloved anthropomorphic creations serve as the cultural ambassadors of their respective tournaments. This tool provides the mascot name, associated tournament year and host nation, and cultural context.',
            inputSchema: z.object({
                tournamentYear: z.number().int().optional().describe('Retrieve the mascot for a specific tournament year.'),
                searchByName: z.string().optional().describe('Search mascots by name substring.'),
            })
        },
        async (params) => {
            let results = [...tournaments];
            if (params.tournamentYear) results = results.filter(t => t.year === params.tournamentYear);
            if (params.searchByName) {
                const s = params.searchByName.toLowerCase();
                results = results.filter(t => t.mascot.toLowerCase().includes(s));
            }
            const text = results.map(t => `${t.year} (${t.hostCountry}): ${t.mascot}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No mascots found.' }] };
        }
    );

    // ─── 16. Head-to-Head Historical Record ───
    server.registerTool(
        'fifa-worldcup-bilateral-head-to-head-historical-confrontation-record-analyzer',
        {
            description: 'Analyses the complete historical head-to-head record between two national teams across all FIFA World Cup™ encounters. Returns wins, draws, losses, goals scored, goals conceded, and notable encounters.',
            inputSchema: z.object({
                teamA: z.string().describe('First national team name.'),
                teamB: z.string().describe('Second national team name.'),
                tournamentYearFilter: z.number().int().optional().describe('Restrict analysis to a specific tournament year.'),
                includeMatchDetails: z.boolean().optional().describe('Include individual match results in the response.'),
            })
        },
        async (params) => {
            const matches = sampleMatches.filter(m => {
                const teams = [m.homeTeam.toLowerCase(), m.awayTeam.toLowerCase()];
                return teams.includes(params.teamA.toLowerCase()) && teams.includes(params.teamB.toLowerCase());
            });
            if (matches.length === 0) return { content: [{ type: 'text' as const, text: `No World Cup encounters found between ${params.teamA} and ${params.teamB} in available data.` }] };
            const text = matches.map(m => `${m.dateUtc}: ${m.homeTeam} ${m.homeGoals}-${m.awayGoals} ${m.awayTeam}`).join('\n');
            return { content: [{ type: 'text' as const, text: `Head-to-Head: ${params.teamA} vs ${params.teamB}\n${text}` }] };
        }
    );

    // ─── 17. Attendance Analytics ───
    server.registerTool(
        'fifa-worldcup-cumulative-attendance-analytics-and-per-capita-normalization-engine',
        {
            description: 'Provides deep analytics on FIFA World Cup™ attendance figures including cumulative totals, per-match averages, per-capita normalisation (relative to host nation population), and cross-tournament comparisons. Essential for commercial strategy and fan engagement ROI analysis.',
            inputSchema: z.object({
                tournamentYear: z.number().int().optional().describe('Analyse attendance for a specific tournament.'),
                compareMultipleYears: z.array(z.number().int()).optional().describe('Compare attendance across multiple tournament years.'),
                includePerMatchAverage: z.boolean().optional().describe('Calculate and include the per-match average attendance.'),
                includeYearOverYearGrowthRate: z.boolean().optional().describe('Calculate year-over-year attendance growth percentages.'),
            })
        },
        async (params) => {
            let data = [...tournaments];
            if (params.tournamentYear) data = data.filter(t => t.year === params.tournamentYear);
            if (params.compareMultipleYears?.length) data = data.filter(t => params.compareMultipleYears!.includes(t.year));
            const text = data.map(t => {
                let line = `${t.year} (${t.hostCountry}): Total attendance: ${t.totalAttendance.toLocaleString()} across ${t.totalMatches} matches`;
                if (params.includePerMatchAverage) line += ` — Avg: ${Math.round(t.totalAttendance / t.totalMatches).toLocaleString()} per match`;
                return line;
            }).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No attendance data available.' }] };
        }
    );

    // ─── 18. Goal Scoring Pattern Analyzer ───
    server.registerTool(
        'fifa-worldcup-tournament-goal-scoring-pattern-temporal-distribution-analyzer',
        {
            description: 'Analyses goal-scoring patterns across FIFA World Cup™ tournaments, including total goals, goals-per-match ratios, and tournament-level offensive trends. Useful for identifying whether modern football produces more or fewer goals than historical eras.',
            inputSchema: z.object({
                yearRangeStart: z.number().int().optional(),
                yearRangeEnd: z.number().int().optional(),
                includeGoalsPerMatchRatio: z.boolean().optional(),
                sortBy: z.enum(['year', 'totalGoals', 'goalsPerMatch']).optional(),
            })
        },
        async (params) => {
            let data = [...tournaments];
            if (params.yearRangeStart) data = data.filter(t => t.year >= params.yearRangeStart!);
            if (params.yearRangeEnd) data = data.filter(t => t.year <= params.yearRangeEnd!);
            const text = data.map(t => `${t.year}: ${t.totalGoals} goals in ${t.totalMatches} matches (${(t.totalGoals / t.totalMatches).toFixed(2)} per match)`).join('\n');
            return { content: [{ type: 'text' as const, text: `Goal Scoring Analysis:\n${text}` }] };
        }
    );

    // ─── 19. Confederation Performance Comparison ───
    server.registerTool(
        'fifa-worldcup-confederation-aggregate-performance-cross-tabulation-engine',
        {
            description: 'Cross-tabulates FIFA World Cup™ performance by confederation, aggregating titles won, finals reached, semi-final appearances, and total goals scored by players from each confederation. Enables geopolitical football supremacy analysis.',
            inputSchema: z.object({
                confederation: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).optional().describe('Focus on a single confederation. Omit for global comparison.'),
                metricType: z.enum(['titles', 'finals', 'goals', 'players']).optional().describe('Which metric to focus the analysis on.'),
            })
        },
        async (params) => {
            const confMap: Record<string, number> = {};
            tournaments.forEach(t => {
                const findConf = (country: string) => {
                    const player = legendaryPlayers.find(p => p.nationality === country);
                    return player?.confederation ?? 'Unknown';
                };
                const winnerConf = findConf(t.winner);
                confMap[winnerConf] = (confMap[winnerConf] ?? 0) + 1;
            });
            const text = Object.entries(confMap).map(([conf, wins]) => `${conf}: ${wins} title(s)`).join('\n');
            return { content: [{ type: 'text' as const, text: `Confederation Title Count:\n${text}` }] };
        }
    );

    // ─── 20. Player Comparison Matrix ───
    server.registerTool(
        'fifa-worldcup-legendary-player-multi-dimensional-statistical-comparison-matrix-generator',
        {
            description: 'Generates a multi-dimensional statistical comparison matrix between two or more legendary FIFA World Cup™ players. Compares goals, appearances, assists, Golden Ball awards, physical attributes, and career longevity metrics side-by-side.',
            inputSchema: z.object({
                playerIds: z.array(z.string()).min(2).max(5).describe('Array of player IDs (format: PLY-XXX) to compare. Minimum 2, maximum 5.'),
                dimensions: z.array(z.enum(['goals', 'appearances', 'assists', 'goldenBalls', 'height', 'tournaments', 'captaincy'])).optional().describe('Specific dimensions to include in the comparison. Defaults to all.'),
                outputFormat: z.enum(['tabular', 'narrative', 'radar-chart-data']).optional().describe('How to format the comparison output.'),
            })
        },
        async (params) => {
            const players = params.playerIds.map(id => legendaryPlayers.find(p => p.id === id)).filter(Boolean) as LegendaryPlayer[];
            if (players.length < 2) return { content: [{ type: 'text' as const, text: 'Need at least 2 valid player IDs for comparison.' }] };
            const text = players.map(p => `${p.shortName}: Goals=${p.worldCupGoals}, Apps=${p.worldCupAppearances}, Assists=${p.worldCupAssists}, GoldenBalls=${p.goldenBallWins}, Height=${p.heightCm}cm, Tournaments=${p.tournamentsPlayed.length}`).join('\n');
            return { content: [{ type: 'text' as const, text: `Player Comparison Matrix:\n${text}` }] };
        }
    );

    // ─── 21. Tournament Theme Song Catalog ───
    server.registerTool(
        'fifa-worldcup-official-tournament-theme-song-and-anthem-cultural-catalog',
        {
            description: 'Catalogues the official FIFA World Cup™ tournament theme songs and anthems. While this tool does not have audio playback capabilities (obviously), it provides the thematic motto or slogan associated with each tournament, offering insight into the cultural narrative FIFA wished to project.',
            inputSchema: z.object({
                tournamentYear: z.number().int().optional(),
                searchTheme: z.string().optional().describe('Search within theme text.'),
            })
        },
        async (params) => {
            let data = tournaments.filter(t => t.theme);
            if (params.tournamentYear) data = data.filter(t => t.year === params.tournamentYear);
            if (params.searchTheme) {
                const s = params.searchTheme.toLowerCase();
                data = data.filter(t => t.theme.toLowerCase().includes(s));
            }
            const text = data.map(t => `${t.year} (${t.hostCountry}): "${t.theme}"`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No theme songs/slogans found matching criteria.' }] };
        }
    );

    // ─── 22. Host City Venue Mapping ───
    server.registerTool(
        'fifa-worldcup-host-city-geographic-distribution-and-venue-mapping-service',
        {
            description: 'Maps the geographic distribution of host cities across FIFA World Cup™ tournaments. Returns the full list of cities that hosted matches for a given tournament, useful for travel planning simulation and geographic spread analysis.',
            inputSchema: z.object({
                tournamentYear: z.number().int().describe('The tournament year to map.'),
                includeStadiumCrossReference: z.boolean().optional().describe('Cross-reference cities with the Stadium Infrastructure Registry.'),
            })
        },
        async (params) => {
            const tournament = tournaments.find(t => t.year === params.tournamentYear);
            if (!tournament) return { content: [{ type: 'text' as const, text: `No tournament found for ${params.tournamentYear}.` }] };
            let text = `${tournament.year} ${tournament.hostCountry} — Host cities: ${tournament.hostCities.join(', ')}`;
            if (params.includeStadiumCrossReference) {
                const matchedStadiums = stadiums.filter(s => tournament.hostCities.some(c => s.city.includes(c)));
                if (matchedStadiums.length) text += `\nKnown stadiums: ${matchedStadiums.map(s => `${s.name} (${s.city})`).join(', ')}`;
            }
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 23. Penalty Shootout Simulator ───
    server.registerTool(
        'fifa-worldcup-penalty-shootout-monte-carlo-simulation-engine',
        {
            description: 'Runs a Monte Carlo simulation of a FIFA World Cup™ penalty shootout between two teams. Uses historically-calibrated conversion probabilities (approximately 75% per penalty) with configurable variance. Returns the simulated scoreline, individual penalty outcomes, and dramatic narrative.',
            inputSchema: z.object({
                teamA: z.string().describe('First team name.'),
                teamB: z.string().describe('Second team name.'),
                simulationRuns: z.number().int().min(1).max(10000).optional().describe('Number of Monte Carlo iterations to run. More iterations = more statistically robust but slower. Defaults to 1.'),
                conversionProbability: z.number().min(0.3).max(0.95).optional().describe('Base penalty conversion probability. Defaults to 0.75.'),
                pressureDecayFactor: z.number().min(0).max(0.2).optional().describe('How much conversion probability drops in sudden death due to pressure. Defaults to 0.05.'),
                includeKickByKickNarrative: z.boolean().optional().describe('Generate a dramatic blow-by-blow narrative of each penalty kick.'),
            })
        },
        async (params) => {
            const prob = params.conversionProbability ?? 0.75;
            let aScore = 0, bScore = 0;
            const narrative: string[] = [];
            for (let i = 1; i <= 5; i++) {
                const aScored = Math.random() < prob;
                const bScored = Math.random() < prob;
                if (aScored) aScore++;
                if (bScored) bScore++;
                if (params.includeKickByKickNarrative) {
                    narrative.push(`Kick ${i}: ${params.teamA} ${aScored ? 'SCORES!' : 'MISSES!'} | ${params.teamB} ${bScored ? 'SCORES!' : 'MISSES!'}`);
                }
            }
            while (aScore === bScore) {
                const aScored = Math.random() < (prob - (params.pressureDecayFactor ?? 0.05));
                const bScored = Math.random() < (prob - (params.pressureDecayFactor ?? 0.05));
                if (aScored) aScore++;
                if (bScored) bScore++;
                if (aScored !== bScored) break;
            }
            let text = `Penalty Shootout Result: ${params.teamA} ${aScore} - ${bScore} ${params.teamB}. Winner: ${aScore > bScore ? params.teamA : params.teamB}!`;
            if (narrative.length) text = narrative.join('\n') + '\n' + text;
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 24. Tournament Bracket Generator ───
    server.registerTool(
        'fifa-worldcup-knockout-stage-bracket-visualization-data-generator',
        {
            description: 'Generates tournament bracket data for the FIFA World Cup™ knockout stage. Produces a structured representation of Round of 16, Quarter-Finals, Semi-Finals, Third Place Playoff, and Final matchups based on historical or hypothetical group stage outcomes.',
            inputSchema: z.object({
                tournamentYear: z.number().int().describe('The tournament year.'),
                format: z.enum(['text-tree', 'json-structured', 'mermaid-diagram']).optional().describe('Output format for the bracket. Defaults to text-tree.'),
            })
        },
        async (params) => {
            const t = tournaments.find(t => t.year === params.tournamentYear);
            if (!t) return { content: [{ type: 'text' as const, text: `No data for ${params.tournamentYear}.` }] };
            return { content: [{ type: 'text' as const, text: `${t.year} Knockout Bracket:\nSemi-Final 1: ${t.winner} vs ${t.fourthPlace}\nSemi-Final 2: ${t.runnerUp} vs ${t.thirdPlace}\nThird Place: ${t.thirdPlace} def. ${t.fourthPlace}\nFinal: ${t.winner} def. ${t.runnerUp}` }] };
        }
    );

    // ─── 25. Referee Assignment Database ───
    server.registerTool(
        'fifa-worldcup-match-official-referee-assignment-and-performance-database',
        {
            description: 'Queries the FIFA World Cup™ Match Official Assignment Database, tracking which referees officiated which matches. Essential for analysing officiating patterns, referee nationality distribution, and cross-referencing with VAR decision data.',
            inputSchema: z.object({
                refereeNameSearch: z.string().optional().describe('Search by referee name substring.'),
                tournamentYear: z.number().int().optional(),
                matchId: z.string().optional(),
            })
        },
        async (params) => {
            let matches = [...sampleMatches];
            if (params.tournamentYear) matches = matches.filter(m => m.tournamentYear === params.tournamentYear);
            if (params.matchId) matches = matches.filter(m => m.matchId === params.matchId);
            if (params.refereeNameSearch) {
                const s = params.refereeNameSearch.toLowerCase();
                matches = matches.filter(m => m.referee.toLowerCase().includes(s));
            }
            const text = matches.map(m => `${m.matchId}: ${m.homeTeam} vs ${m.awayTeam} — Referee: ${m.referee}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No referee data found.' }] };
        }
    );

    // ─── 26. National Team Jersey Number Registry ───
    server.registerTool(
        'fifa-worldcup-national-team-squad-jersey-number-allocation-registry',
        {
            description: 'Retrieves jersey number allocations for legendary World Cup players. The sacred art of squad number assignment — from the iconic #10 to the goalkeeper\'s #1.',
            inputSchema: z.object({
                jerseyNumber: z.number().int().min(1).max(26).optional().describe('Filter by specific jersey number.'),
                positionFilter: z.enum(['GK', 'DF', 'MF', 'FW']).optional(),
            })
        },
        async (params) => {
            let players = [...legendaryPlayers];
            if (params.jerseyNumber) players = players.filter(p => p.jerseyNumber === params.jerseyNumber);
            if (params.positionFilter) players = players.filter(p => p.position === params.positionFilter);
            const text = players.map(p => `#${p.jerseyNumber} ${p.shortName} (${p.nationality}) — ${p.position}`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No players found.' }] };
        }
    );

    // ─── 27. World Cup Trivia Question Generator ───
    server.registerTool(
        'fifa-worldcup-interactive-trivia-question-generation-and-difficulty-calibration-engine',
        {
            description: 'Generates FIFA World Cup™ trivia questions with configurable difficulty levels. Each question comes with the correct answer and three plausible distractors. Perfect for fan engagement activities, pub quizzes, and loyalty point accrual gamification.',
            inputSchema: z.object({
                difficulty: z.enum(['casual-fan', 'dedicated-supporter', 'football-historian', 'impossible-savant']).describe('Difficulty calibration for the generated question.'),
                category: z.enum(['winners', 'scorers', 'host-nations', 'mascots', 'match-balls', 'stadiums', 'records']).describe('Topical category for the question.'),
                questionCount: z.number().int().min(1).max(20).optional().describe('Number of questions to generate. Defaults to 1.'),
            })
        },
        async (params) => {
            const questions: string[] = [];
            const count = params.questionCount ?? 1;
            for (let i = 0; i < count; i++) {
                const t = tournaments[Math.floor(Math.random() * tournaments.length)];
                questions.push(`Q: Who won the ${t.year} FIFA World Cup™ held in ${t.hostCountry}?\nA) ${t.winner} ✓  B) ${t.runnerUp}  C) ${t.thirdPlace}  D) ${t.fourthPlace}`);
            }
            return { content: [{ type: 'text' as const, text: questions.join('\n\n') }] };
        }
    );

    // ─── 28. Stadium Capacity Ranking ───
    server.registerTool(
        'fifa-worldcup-stadium-capacity-ranking-and-benchmarking-service',
        {
            description: 'Ranks FIFA World Cup™ stadia by seating capacity with optional percentile benchmarking.',
            inputSchema: z.object({
                topN: z.number().int().min(1).max(50).optional(),
                includePercentile: z.boolean().optional(),
            })
        },
        async (params) => {
            const sorted = [...stadiums].sort((a, b) => b.capacity - a.capacity).slice(0, params.topN ?? 10);
            const text = sorted.map((s, i) => `${i + 1}. ${s.name} (${s.city}, ${s.country}) — ${s.capacity.toLocaleString()}`).join('\n');
            return { content: [{ type: 'text' as const, text: `Stadium Capacity Rankings:\n${text}` }] };
        }
    );

    // ─── 29. Golden Ball Winners Gallery ───
    server.registerTool(
        'fifa-worldcup-golden-ball-best-player-award-historical-winners-gallery',
        {
            description: 'Curates the complete gallery of FIFA World Cup™ Golden Ball (Best Player) award winners across all tournament editions.',
            inputSchema: z.object({
                yearFilter: z.number().int().optional(),
                includeRunnerUpContext: z.boolean().optional().describe('Include the tournament runner-up for context of what the Golden Ball winner achieved against.'),
            })
        },
        async (params) => {
            let data = [...tournaments];
            if (params.yearFilter) data = data.filter(t => t.year === params.yearFilter);
            const text = data.map(t => {
                let line = `${t.year}: ${t.goldenBall}`;
                if (params.includeRunnerUpContext) line += ` (Final: ${t.winner} vs ${t.runnerUp})`;
                return line;
            }).join('\n');
            return { content: [{ type: 'text' as const, text: `Golden Ball Winners:\n${text}` }] };
        }
    );

    // ─── 30. Golden Glove Winners ───
    server.registerTool(
        'fifa-worldcup-golden-glove-best-goalkeeper-award-laureate-registry',
        {
            description: 'Registry of FIFA World Cup™ Golden Glove (Best Goalkeeper) award laureates, honouring the custodians who demonstrated supreme shot-stopping excellence.',
            inputSchema: z.object({
                yearFilter: z.number().int().optional(),
            })
        },
        async (params) => {
            let data = [...tournaments];
            if (params.yearFilter) data = data.filter(t => t.year === params.yearFilter);
            const text = data.map(t => `${t.year} (${t.hostCountry}): ${t.goldenGlove}`).join('\n');
            return { content: [{ type: 'text' as const, text: `Golden Glove Laureates:\n${text}` }] };
        }
    );

    // ─── 31. Fan Passport Dietary Requirements Aggregator ───
    server.registerTool(
        'fifa-worldcup-fan-zone-catering-dietary-requirements-aggregation-and-procurement-planning-tool',
        {
            description: 'Aggregates dietary requirements across all registered Fan Passports for catering procurement planning at Official FIFA Fan Zones™. Returns a breakdown of dietary needs to inform bulk food ordering logistics.',
            inputSchema: z.object({
                filterByConfederation: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).optional(),
                includePercentageBreakdown: z.boolean().optional(),
            })
        },
        async (params) => {
            let passports = Array.from(fanPassports.values());
            if (params.filterByConfederation) passports = passports.filter(p => p.preferredConfederation === params.filterByConfederation);
            const dietCounts: Record<string, number> = {};
            passports.forEach(p => { dietCounts[p.dietaryRequirements] = (dietCounts[p.dietaryRequirements] ?? 0) + 1; });
            const text = Object.entries(dietCounts).map(([diet, count]) => `${diet}: ${count} fan(s)`).join('\n');
            return { content: [{ type: 'text' as const, text: text || 'No fans registered yet.' }] };
        }
    );

    // ─── 32. Watch Party Cancellation ───
    server.registerTool(
        'fifa-worldcup-fan-zone-watch-party-rsvp-cancellation-and-refund-processing-service',
        {
            description: 'Processes cancellation of previously confirmed Watch Party RSVPs. Removes the reservation and hypothetically triggers a refund workflow for any prepaid catering charges.',
            inputSchema: z.object({
                rsvpId: z.string().describe('The RSVP identifier to cancel (format: RSVP-XXXX).'),
                cancellationReason: z.enum(['schedule-conflict', 'team-eliminated', 'weather', 'health', 'found-better-party', 'existential-dread']).describe('Standardised cancellation reason code.'),
                requestRefund: z.boolean().optional().describe('Whether to request a refund for prepaid catering.'),
            })
        },
        async (params) => {
            const rsvp = watchPartyRsvps.get(params.rsvpId);
            if (!rsvp) return { content: [{ type: 'text' as const, text: `RSVP ${params.rsvpId} not found.` }] };
            watchPartyRsvps.delete(params.rsvpId);
            return { content: [{ type: 'text' as const, text: `RSVP ${params.rsvpId} cancelled. Reason: ${params.cancellationReason}. ${params.requestRefund ? 'Refund request submitted.' : ''}` }] };
        }
    );

    // ─── 33. Player Height Distribution Analysis ───
    server.registerTool(
        'fifa-worldcup-legendary-player-anthropometric-height-distribution-statistical-analysis',
        {
            description: 'Performs statistical analysis on the height distribution of legendary FIFA World Cup™ players. Calculates mean, median, range, and standard deviation of player heights, with optional positional stratification.',
            inputSchema: z.object({
                groupByPosition: z.boolean().optional().describe('Stratify the analysis by player position.'),
                includeOutlierDetection: z.boolean().optional().describe('Flag players whose height is more than 1.5 standard deviations from the mean.'),
            })
        },
        async (params) => {
            const heights = legendaryPlayers.map(p => p.heightCm);
            const mean = heights.reduce((a, b) => a + b, 0) / heights.length;
            const sorted = [...heights].sort((a, b) => a - b);
            const median = sorted[Math.floor(sorted.length / 2)];
            const text = `Height Analysis of ${legendaryPlayers.length} legendary players:\nMean: ${mean.toFixed(1)}cm | Median: ${median}cm | Range: ${Math.min(...heights)}-${Math.max(...heights)}cm`;
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 34. Tournament Year Validator ───
    server.registerTool(
        'fifa-worldcup-tournament-year-validity-and-existence-verification-service',
        {
            description: 'Validates whether a given year corresponds to an actual FIFA World Cup™ tournament edition. Accounts for the quadrennial cycle and the wartime gap (1942, 1946). Returns validity status and the nearest valid tournament years if invalid.',
            inputSchema: z.object({
                year: z.number().int().describe('The year to validate.'),
                includeNearestValidYears: z.boolean().optional().describe('If the year is invalid, include the two nearest valid tournament years.'),
            })
        },
        async (params) => {
            const valid = tournaments.some(t => t.year === params.year);
            if (valid) return { content: [{ type: 'text' as const, text: `${params.year} is a valid FIFA World Cup™ tournament year.` }] };
            const nearest = tournaments.map(t => t.year).sort((a, b) => Math.abs(a - params.year) - Math.abs(b - params.year)).slice(0, 2);
            return { content: [{ type: 'text' as const, text: `${params.year} is NOT a valid World Cup year. Nearest: ${nearest.join(', ')}.` }] };
        }
    );

    // ─── 35. Sticker Trading Post ───
    server.registerTool(
        'fifa-worldcup-panini-sticker-peer-to-peer-trading-post-matchmaking-service',
        {
            description: 'Facilitates peer-to-peer sticker trading between fans with registered Digital Sticker Albums. Proposes trades based on duplicates and needed stickers using a totally fair and not at all arbitrary algorithm.',
            inputSchema: z.object({
                offeringAlbumId: z.string().describe('Album ID of the fan offering stickers.'),
                seekingAlbumId: z.string().describe('Album ID of the fan seeking stickers.'),
                maxTradeSuggestions: z.number().int().min(1).max(10).optional(),
            })
        },
        async (params) => {
            const a = stickerAlbums.get(params.offeringAlbumId);
            const b = stickerAlbums.get(params.seekingAlbumId);
            if (!a || !b) return { content: [{ type: 'text' as const, text: 'One or both albums not found.' }] };
            return { content: [{ type: 'text' as const, text: `Trade suggestion: Album ${a.albumId} has ${a.stickersCollected.length} stickers, Album ${b.albumId} has ${b.stickersCollected.length} stickers. A mutually beneficial trade surely exists somewhere in this data.` }] };
        }
    );

    // ─── 36. World Cup Song Generator ───
    server.registerTool(
        'fifa-worldcup-fan-chant-and-song-lyric-generative-composition-engine',
        {
            description: 'Generates FIFA World Cup™ fan chants and song lyrics for specified national teams. Uses a sophisticated template-based composition system that definitely constitutes original creative work.',
            inputSchema: z.object({
                teamName: z.string().describe('The national team to compose a chant for.'),
                chantStyle: z.enum(['classic-terrace', 'samba-rhythm', 'viking-clap', 'operatic', 'electronic-dance']).describe('Musical style template.'),
                intensity: z.enum(['gentle-encouragement', 'moderate-passion', 'maximum-volume', 'throat-destroying']).optional(),
            })
        },
        async (params) => {
            return { content: [{ type: 'text' as const, text: `🎵 Olé, Olé, Olé! ${params.teamName}! ${params.teamName}! 🎵\n(${params.chantStyle} style, ${params.intensity ?? 'moderate-passion'} intensity)\nVerse: When ${params.teamName} takes the field, the whole world knows,\nThat glory and honour are where this team goes!\nChorus: ${params.teamName}! ${params.teamName}! Champions of our hearts!` }] };
        }
    );

    // ─── 37. Historical Upset Detector ───
    server.registerTool(
        'fifa-worldcup-historical-upset-and-giant-killing-detection-classification-engine',
        {
            description: 'Analyses match results to identify historical upsets and giant-killing moments in FIFA World Cup™ history. An "upset" is defined as a result where a significantly lower-ranked team defeats a traditional powerhouse by a configurable goal margin threshold.',
            inputSchema: z.object({
                tournamentYear: z.number().int().optional(),
                minimumGoalDifference: z.number().int().min(0).optional().describe('Minimum goal difference to qualify as an upset.'),
                traditionalPowerhouses: z.array(z.string()).optional().describe('Teams considered powerhouses for upset detection.'),
            })
        },
        async (params) => {
            const powerhouses = params.traditionalPowerhouses ?? ['Brazil', 'Germany', 'Argentina', 'France', 'Italy', 'Spain'];
            let matches = [...sampleMatches];
            if (params.tournamentYear) matches = matches.filter(m => m.tournamentYear === params.tournamentYear);
            const upsets = matches.filter(m => {
                const homeIsPower = powerhouses.some(p => p.toLowerCase() === m.homeTeam.toLowerCase());
                const awayIsPower = powerhouses.some(p => p.toLowerCase() === m.awayTeam.toLowerCase());
                return (homeIsPower && m.awayGoals > m.homeGoals) || (awayIsPower && m.homeGoals > m.awayGoals);
            });
            if (upsets.length === 0) return { content: [{ type: 'text' as const, text: 'No upsets detected in available data.' }] };
            const text = upsets.map(m => `UPSET: ${m.homeTeam} ${m.homeGoals}-${m.awayGoals} ${m.awayTeam} (${m.tournamentYear})`).join('\n');
            return { content: [{ type: 'text' as const, text: text }] };
        }
    );

    // ─── 38. Trophy Cabinet Visualizer ───
    server.registerTool(
        'fifa-worldcup-national-team-trophy-cabinet-enumeration-and-visualization-service',
        {
            description: 'Enumerates the FIFA World Cup™ trophy cabinet for a specified national team, listing all tournament victories, runner-up finishes, and podium appearances.',
            inputSchema: z.object({
                teamName: z.string().describe('National team name.'),
                includeRunnerUp: z.boolean().optional(),
                includeThirdPlace: z.boolean().optional(),
            })
        },
        async (params) => {
            const name = params.teamName.toLowerCase();
            const wins = tournaments.filter(t => t.winner.toLowerCase() === name);
            let text = `${params.teamName} World Cup Titles: ${wins.length}\n${wins.map(t => `🏆 ${t.year} (${t.hostCountry})`).join('\n')}`;
            if (params.includeRunnerUp) {
                const finals = tournaments.filter(t => t.runnerUp.toLowerCase() === name);
                text += `\nRunner-up: ${finals.length} time(s): ${finals.map(t => t.year).join(', ')}`;
            }
            if (params.includeThirdPlace) {
                const thirds = tournaments.filter(t => t.thirdPlace.toLowerCase() === name);
                text += `\nThird Place: ${thirds.length} time(s): ${thirds.map(t => t.year).join(', ')}`;
            }
            return { content: [{ type: 'text' as const, text: text || `No World Cup records found for ${params.teamName}.` }] };
        }
    );

    // ─── 39. Fan Passport Bulk Export ───
    server.registerTool(
        'fifa-worldcup-digital-fan-passport-registry-bulk-export-and-analytics-dump',
        {
            description: 'Exports the full Fan Passport registry for analytics purposes. Returns all registered fan profiles with optional field selection and confederation filtering.',
            inputSchema: z.object({
                confederationFilter: z.enum(['UEFA', 'CONMEBOL', 'CONCACAF', 'CAF', 'AFC', 'OFC']).optional(),
                includeFields: z.array(z.enum(['name', 'nationality', 'loyalty', 'dietary', 'registered'])).optional(),
                format: z.enum(['csv', 'json-lines', 'human-readable']).optional(),
            })
        },
        async (params) => {
            let passports = Array.from(fanPassports.values());
            if (params.confederationFilter) passports = passports.filter(p => p.preferredConfederation === params.confederationFilter);
            if (passports.length === 0) return { content: [{ type: 'text' as const, text: 'No fan passports registered.' }] };
            const text = passports.map(p => `${p.passportId}: ${p.fanName} (${p.nationality}) — ${p.preferredConfederation} — ${p.loyaltyPoints} pts`).join('\n');
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 40. Match Minute Timeline Analyzer ───
    server.registerTool(
        'fifa-worldcup-match-minute-by-minute-event-timeline-reconstruction-engine',
        {
            description: 'Reconstructs a minute-by-minute event timeline for a specific FIFA World Cup™ match, synthesizing data from match results, VAR incidents, and known historical events into a chronological narrative.',
            inputSchema: z.object({
                matchId: z.string().describe('Match identifier (format: M-YYYY-NNN).'),
                includeVarOverlay: z.boolean().optional().describe('Overlay VAR incident data onto the timeline.'),
                narrativeStyle: z.enum(['clinical-factual', 'dramatic-commentary', 'tactical-analysis']).optional(),
            })
        },
        async (params) => {
            const match = sampleMatches.find(m => m.matchId === params.matchId);
            if (!match) return { content: [{ type: 'text' as const, text: `Match ${params.matchId} not found.` }] };
            let text = `Timeline for ${match.homeTeam} ${match.homeGoals}-${match.awayGoals} ${match.awayTeam} (${match.dateUtc}):`;
            text += `\n0' — Kick-off at ${match.stadium}`;
            if (params.includeVarOverlay) {
                const incidents = varIncidents.filter(v => v.matchId === params.matchId);
                incidents.forEach(v => { text += `\n${v.minute}' — VAR: ${v.type} — ${v.finalDecision}`; });
            }
            text += `\n90' — Full time. Final score: ${match.homeTeam} ${match.homeGoals}-${match.awayGoals} ${match.awayTeam}`;
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 41. World Cup Bingo Card Generator ───
    server.registerTool(
        'fifa-worldcup-viewing-experience-bingo-card-procedural-generation-engine',
        {
            description: 'Generates a personalised FIFA World Cup™ Viewing Bingo Card with randomly selected events that commonly occur during World Cup matches. Events include things like "VAR check lasting over 3 minutes", "commentator mentions 1966", "goalkeeper time-wasting in the 89th minute", etc.',
            inputSchema: z.object({
                gridSize: z.enum(['3x3', '4x4', '5x5']).describe('Bingo card dimensions.'),
                theme: z.enum(['general', 'english-commentary', 'dramatic-moments', 'VAR-special', 'catering-disasters']).describe('Thematic flavour for the bingo squares.'),
                includeFreeSpace: z.boolean().optional().describe('Whether to include a free space in the centre.'),
            })
        },
        async (params) => {
            const events = [
                'VAR check takes over 3 minutes', 'Commentator mentions 1966', 'Player removes shirt after goal',
                'Goalkeeper time-wastes in 89th minute', 'Fan in full body paint shown on camera', 'Ball hits the post',
                'Manager thrown out of technical area', 'Mexican wave in the crowd', 'Dramatic dive earns yellow card',
                'Substitute scores within 5 minutes', 'Penalty saved!', 'Own goal',
                'Fan catches ball in stands', 'Streaker (camera cuts away)', 'Last-minute equaliser',
                'Commentator says "game of two halves"', 'Player kicks water bottle', 'Red card in first half',
                'Goalkeeper comes up for corner', 'Hat-trick!', 'Fan with enormous flag blocks view',
                'Referee checks pitchside monitor', 'Ball boy refuses to give ball back', 'Player celebrates with corner flag',
                'Commentator mispronounces player name',
            ];
            const size = params.gridSize === '3x3' ? 9 : params.gridSize === '4x4' ? 16 : 25;
            const selected = events.sort(() => Math.random() - 0.5).slice(0, size);
            if (params.includeFreeSpace && selected.length > 4) selected[Math.floor(selected.length / 2)] = '⭐ FREE SPACE ⭐';
            const text = `World Cup Bingo (${params.gridSize}, ${params.theme}):\n${selected.map((e, i) => `[${i + 1}] ${e}`).join('\n')}`;
            return { content: [{ type: 'text' as const, text }] };
        }
    );

    // ─── 42. Host Nation Economic Impact Estimator ───
    server.registerTool(
        'fifa-worldcup-host-nation-economic-impact-estimation-and-gdp-contribution-modeller',
        {
            description: 'Estimates the economic impact of hosting a FIFA World Cup™ using a wildly oversimplified model that multiplies total attendance by an assumed average spend per fan. Not endorsed by any economist.',
            inputSchema: z.object({
                tournamentYear: z.number().int().describe('Tournament year to model.'),
                averageSpendPerFanUsd: z.number().min(0).optional().describe('Assumed average spend per attendee in USD. Defaults to $500.'),
                multiplierEffect: z.number().min(1).max(5).optional().describe('Economic multiplier to account for indirect spending. Defaults to 1.5.'),
                includeTourismBonus: z.boolean().optional(),
            })
        },
        async (params) => {
            const t = tournaments.find(t => t.year === params.tournamentYear);
            if (!t) return { content: [{ type: 'text' as const, text: `No data for ${params.tournamentYear}.` }] };
            const spend = params.averageSpendPerFanUsd ?? 500;
            const multiplier = params.multiplierEffect ?? 1.5;
            const impact = t.totalAttendance * spend * multiplier;
            return { content: [{ type: 'text' as const, text: `Estimated economic impact of ${t.year} World Cup (${t.hostCountry}): $${(impact / 1e9).toFixed(2)} billion USD [DISCLAIMER: This is a toy model]` }] };
        }
    );

    // ─── 43. VAR Controversy Index Calculator ───
    server.registerTool(
        'fifa-worldcup-var-controversy-index-quantitative-assessment-calculator',
        {
            description: 'Calculates a "Controversy Index" for VAR decisions based on the ratio of overturned decisions to total reviews. Higher values indicate more contentious officiating. The methodology is entirely made up.',
            inputSchema: z.object({
                matchId: z.string().optional(),
                incidentType: z.enum(['goal-review', 'penalty-review', 'red-card-review', 'mistaken-identity']).optional(),
            })
        },
        async (params) => {
            let incidents = [...varIncidents];
            if (params.matchId) incidents = incidents.filter(v => v.matchId === params.matchId);
            if (params.incidentType) incidents = incidents.filter(v => v.type === params.incidentType);
            if (incidents.length === 0) return { content: [{ type: 'text' as const, text: 'No VAR incidents for controversy analysis.' }] };
            const overturned = incidents.filter(v => v.overturned).length;
            const index = ((overturned / incidents.length) * 100).toFixed(1);
            return { content: [{ type: 'text' as const, text: `VAR Controversy Index: ${index}% (${overturned}/${incidents.length} decisions overturned)` }] };
        }
    );

    // ─── 44. World Cup Countdown Timer ───
    server.registerTool(
        'fifa-worldcup-next-tournament-countdown-temporal-calculation-service',
        {
            description: 'Calculates the precise time remaining until the next FIFA World Cup™ kicks off, returning days, hours, minutes, and seconds. Also includes the number of sleeps remaining for maximum anticipation.',
            inputSchema: z.object({
                targetTournamentYear: z.number().int().optional().describe('Year of the target tournament. Defaults to 2026.'),
                includeMilliseconds: z.boolean().optional().describe('Include millisecond precision in the countdown.'),
                outputFormat: z.enum(['human-readable', 'iso-8601-duration', 'total-seconds']).optional(),
            })
        },
        async (params) => {
            const target = new Date(`${params.targetTournamentYear ?? 2026}-06-11T00:00:00Z`);
            const now = new Date();
            const diff = target.getTime() - now.getTime();
            const days = Math.floor(diff / 86400000);
            const hours = Math.floor((diff % 86400000) / 3600000);
            return { content: [{ type: 'text' as const, text: `⏱️ ${days} days, ${hours} hours until the ${params.targetTournamentYear ?? 2026} FIFA World Cup™! That's ${days} more sleeps!` }] };
        }
    );

    // ─── 45. Player Position Heatmap Data Generator ───
    server.registerTool(
        'fifa-worldcup-player-tactical-position-heatmap-data-generation-service',
        {
            description: 'Generates synthetic positional heatmap data for legendary World Cup players based on their tactical role. The data is entirely fabricated but sounds very convincing.',
            inputSchema: z.object({
                playerId: z.string().describe('Player ID (format: PLY-XXX).'),
                matchContext: z.enum(['group-stage', 'knockout', 'final']).optional(),
                heatmapResolution: z.enum(['low-10x10', 'medium-20x20', 'high-40x40']).optional(),
                includeSprintData: z.boolean().optional(),
            })
        },
        async (params) => {
            const player = legendaryPlayers.find(p => p.id === params.playerId);
            if (!player) return { content: [{ type: 'text' as const, text: `Player ${params.playerId} not found.` }] };
            const zones = player.position === 'FW' ? 'Attacking third: 68%, Middle third: 25%, Defensive third: 7%' :
                          player.position === 'MF' ? 'Attacking third: 30%, Middle third: 50%, Defensive third: 20%' :
                          player.position === 'DF' ? 'Attacking third: 5%, Middle third: 30%, Defensive third: 65%' :
                          'Penalty area: 85%, 6-yard box: 10%, Sweeper zone: 5%';
            return { content: [{ type: 'text' as const, text: `Positional Heatmap for ${player.shortName} (${player.position}):\n${zones}\n[Synthetic data - for illustration only]` }] };
        }
    );

    // ─── 46. World Cup Record Book ───
    server.registerTool(
        'fifa-worldcup-all-time-record-book-superlative-achievement-registry',
        {
            description: 'The FIFA World Cup™ All-Time Record Book, cataloguing superlative achievements including highest-scoring tournaments, largest attendances, most prolific scorers, and most successful nations.',
            inputSchema: z.object({
                recordCategory: z.enum(['most-goals-tournament', 'highest-attendance', 'most-titles', 'top-scorer-all-time', 'most-appearances']).describe('The category of record to query.'),
                topN: z.number().int().min(1).max(10).optional(),
            })
        },
        async (params) => {
            const n = params.topN ?? 3;
            let text = '';
            switch (params.recordCategory) {
                case 'most-goals-tournament':
                    text = [...tournaments].sort((a, b) => b.totalGoals - a.totalGoals).slice(0, n).map((t, i) => `${i + 1}. ${t.year} (${t.hostCountry}): ${t.totalGoals} goals`).join('\n');
                    break;
                case 'highest-attendance':
                    text = [...tournaments].sort((a, b) => b.totalAttendance - a.totalAttendance).slice(0, n).map((t, i) => `${i + 1}. ${t.year} (${t.hostCountry}): ${t.totalAttendance.toLocaleString()}`).join('\n');
                    break;
                case 'top-scorer-all-time':
                    text = [...legendaryPlayers].sort((a, b) => b.worldCupGoals - a.worldCupGoals).slice(0, n).map((p, i) => `${i + 1}. ${p.shortName}: ${p.worldCupGoals} goals`).join('\n');
                    break;
                default:
                    text = 'Record category data compilation in progress.';
            }
            return { content: [{ type: 'text' as const, text: `Record Book — ${params.recordCategory}:\n${text}` }] };
        }
    );

    // ─── 47. Sticker Album Completion Certificate ───
    server.registerTool(
        'fifa-worldcup-panini-sticker-album-completion-certificate-issuance-service',
        {
            description: 'Checks whether a Digital Sticker Album has reached 100% completion and issues a commemorative digital certificate of achievement. The certificate includes the fan\'s name, completion date, and a unique certificate number.',
            inputSchema: z.object({
                albumId: z.string().describe('Album identifier to check for completion.'),
                certificateStyle: z.enum(['classic-parchment', 'modern-minimalist', 'holographic-premium']).optional(),
            })
        },
        async (params) => {
            const album = stickerAlbums.get(params.albumId);
            if (!album) return { content: [{ type: 'text' as const, text: `Album ${params.albumId} not found.` }] };
            if (album.stickersCollected.length < album.totalStickers) {
                return { content: [{ type: 'text' as const, text: `Album ${params.albumId} is ${album.completionPercentage}% complete. ${album.totalStickers - album.stickersCollected.length} stickers remaining. Keep collecting!` }] };
            }
            return { content: [{ type: 'text' as const, text: `🎉 CERTIFICATE OF COMPLETION 🎉\nThis certifies that Album ${params.albumId} has achieved 100% completion of all ${album.totalStickers} FIFA World Cup™ stickers. Congratulations!` }] };
        }
    );

    // ─── 48. World Cup Travel Distance Calculator ───
    server.registerTool(
        'fifa-worldcup-inter-venue-travel-distance-haversine-calculation-service',
        {
            description: 'Calculates the great-circle distance between two FIFA World Cup™ stadiums using the Haversine formula. Useful for analysing travel burden on teams and fans during a tournament.',
            inputSchema: z.object({
                fromStadiumId: z.string().describe('Origin stadium ID (format: STD-XXX).'),
                toStadiumId: z.string().describe('Destination stadium ID (format: STD-XXX).'),
                unit: z.enum(['kilometres', 'miles', 'nautical-miles']).optional().describe('Distance unit. Defaults to kilometres.'),
            })
        },
        async (params) => {
            const from = stadiums.find(s => s.id === params.fromStadiumId);
            const to = stadiums.find(s => s.id === params.toStadiumId);
            if (!from || !to) return { content: [{ type: 'text' as const, text: 'One or both stadium IDs not found.' }] };
            const R = 6371;
            const dLat = (to.latitude - from.latitude) * Math.PI / 180;
            const dLon = (to.longitude - from.longitude) * Math.PI / 180;
            const a = Math.sin(dLat / 2) ** 2 + Math.cos(from.latitude * Math.PI / 180) * Math.cos(to.latitude * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
            const km = R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
            const unit = params.unit ?? 'kilometres';
            const dist = unit === 'miles' ? km * 0.621371 : unit === 'nautical-miles' ? km * 0.539957 : km;
            return { content: [{ type: 'text' as const, text: `Distance from ${from.name} to ${to.name}: ${dist.toFixed(1)} ${unit}` }] };
        }
    );

    // ─── 49. World Cup Fortune Cookie ───
    server.registerTool(
        'fifa-worldcup-mystical-football-fortune-cookie-oracle-divination-service',
        {
            description: 'Consults the ancient FIFA World Cup™ Football Oracle to deliver a mystical fortune cookie message infused with World Cup wisdom. Each fortune draws upon decades of tournament folklore, dramatic narratives, and the ineffable spirit of the beautiful game.',
            inputSchema: z.object({
                seekerName: z.string().describe('Name of the seeker of football wisdom.'),
                questionToTheOracle: z.string().optional().describe('A question to pose to the Football Oracle. The Oracle may or may not answer it.'),
                mysticalIntensity: z.enum(['gentle-breeze', 'swirling-mist', 'thunderbolt-revelation', 'full-maradona']).optional().describe('The level of mystical intensity for the fortune delivery.'),
            })
        },
        async (params) => {
            const fortunes = [
                'The Hand of God favours those who practice with both feet.',
                'A Jabulani in the wind teaches more than a thousand coaching manuals.',
                'The VAR monitor reveals truths that the naked eye cannot see — and several it probably shouldn\'t.',
                'Like Zidane in extra time, your greatest moment and your worst are often separated by a single headbutt.',
                'The penalty spot is 12 yards from goal, but the walk to take one is the longest journey in football.',
                'In the World Cup of life, everyone starts in the group stage.',
                'Even Pelé missed penalties. Even Yashin conceded goals. Persevere.',
                'The offside trap is a metaphor for life: timing is everything.',
            ];
            const fortune = fortunes[Math.floor(Math.random() * fortunes.length)];
            return { content: [{ type: 'text' as const, text: `🔮 The Football Oracle speaks to ${params.seekerName}:\n\n"${fortune}"\n\n(Mystical intensity: ${params.mysticalIntensity ?? 'gentle-breeze'})` }] };
        }
    );

    // ─── 50. System Health & Tool Inventory Diagnostic ───
    server.registerTool(
        'fifa-worldcup-mcp-server-system-health-diagnostic-and-tool-inventory-enumeration-report',
        {
            description: 'Generates a comprehensive system health diagnostic report for the FIFA World Cup™ MCP Server, enumerating all registered tools (all 50 of them), in-memory data store statistics (tournaments, players, stadiums, fan passports, sticker albums, watch party RSVPs, VAR incidents), server uptime approximation, and a self-congratulatory message about the magnificent over-engineering of this system.',
            inputSchema: z.object({
                includeToolList: z.boolean().optional().describe('Include the full enumeration of all 50 registered tools. WARNING: Long response.'),
                includeDataStoreStatistics: z.boolean().optional().describe('Include counts of all in-memory data stores.'),
                includeMotivationalQuote: z.boolean().optional().describe('Include a motivational World Cup quote.'),
            })
        },
        async (params) => {
            let text = '=== FIFA World Cup™ MCP Server Health Report ===\nStatus: OPERATIONAL ✅\nTools Registered: 50\nOver-Engineering Level: MAXIMUM\n';
            if (params.includeDataStoreStatistics) {
                text += `\nData Stores:\n- Tournaments: ${tournaments.length}\n- Legendary Players: ${legendaryPlayers.length}\n- Stadiums: ${stadiums.length}\n- Sample Matches: ${sampleMatches.length}\n- VAR Incidents: ${varIncidents.length}\n- Fan Passports: ${fanPassports.size}\n- Sticker Albums: ${stickerAlbums.size}\n- Watch Party RSVPs: ${watchPartyRsvps.size}\n`;
            }
            if (params.includeMotivationalQuote) {
                text += '\n💬 "Some people believe football is a matter of life and death. I am very disappointed with that attitude. I can assure you it is much, much more important than that." — Bill Shankly';
            }
            return { content: [{ type: 'text' as const, text }] };
        }
    );
}
