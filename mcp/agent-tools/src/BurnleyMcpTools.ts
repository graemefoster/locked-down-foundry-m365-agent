import fs from 'node:fs';
import path from 'node:path';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

type Fixture = {
    id: string;
    date: string;
    competition: string;
    home: string;
    away: string;
    venue: string;
    ticketsAvailable: number;
};

type Product = {
    sku: string;
    name: string;
    category: 'replica-shirt' | 'replica-shorts' | 'training' | 'outerwear' | 'accessories';
    priceGbp: number;
    colors: string[];
    sizes: string[];
    stockByColorAndSize: Record<string, Record<string, number>>;
};

type ProductCategory = Product['category'];

const supportedCategories: ProductCategory[] = ['replica-shirt', 'replica-shorts', 'training', 'outerwear', 'accessories'];


const fixtures: Fixture[] = [
    {
        id: 'FIX-1001',
        date: '2026-05-16 15:00',
        competition: 'EFL Championship',
        home: 'Burnley',
        away: 'Sunderland',
        venue: 'Turf Moor',
        ticketsAvailable: 3200
    },
    {
        id: 'FIX-1002',
        date: '2026-05-23 12:30',
        competition: 'EFL Championship',
        home: 'Bristol City',
        away: 'Burnley',
        venue: 'Ashton Gate',
        ticketsAvailable: 1200
    },
    {
        id: 'FIX-1003',
        date: '2026-05-30 15:00',
        competition: 'FA Cup',
        home: 'Burnley',
        away: 'West Ham',
        venue: 'Turf Moor',
        ticketsAvailable: 2800
    }
];

const products: Product[] = [
    {
        sku: 'BFC-HOME-SS-26',
        name: 'Burnley Home Replica Shirt 2026/27',
        category: 'replica-shirt',
        priceGbp: 65,
        colors: ['claret-blue'],
        sizes: ['S', 'M', 'L', 'XL', '2XL'],
        stockByColorAndSize: {
            'claret-blue': { S: 12, M: 24, L: 18, XL: 8, '2XL': 5 }
        }
    },
    {
        sku: 'BFC-AWAY-SS-26',
        name: 'Burnley Away Replica Shirt 2026/27',
        category: 'replica-shirt',
        priceGbp: 65,
        colors: ['ivory', 'black'],
        sizes: ['S', 'M', 'L', 'XL'],
        stockByColorAndSize: {
            ivory: { S: 6, M: 11, L: 7, XL: 4 },
            black: { S: 10, M: 15, L: 9, XL: 6 }
        }
    },
    {
        sku: 'BFC-TRN-HOOD-26',
        name: 'Burnley Training Hoodie',
        category: 'training',
        priceGbp: 52,
        colors: ['navy', 'claret'],
        sizes: ['XS', 'S', 'M', 'L', 'XL', '2XL'],
        stockByColorAndSize: {
            navy: { XS: 4, S: 10, M: 12, L: 9, XL: 5, '2XL': 2 },
            claret: { XS: 3, S: 7, M: 10, L: 8, XL: 4, '2XL': 2 }
        }
    },
    {
        sku: 'BFC-SCARF-CLRT',
        name: 'Burnley Crest Scarf',
        category: 'accessories',
        priceGbp: 18,
        colors: ['claret-blue'],
        sizes: ['ONE-SIZE'],
        stockByColorAndSize: {
            'claret-blue': { 'ONE-SIZE': 40 }
        }
    }
];

const ticketBookings = new Map<string, { fixtureId: string; customerName: string; quantity: number }>();

function readHistoryText(): string {
    const historyPath = path.resolve(__dirname, 'history.txt');
    try {
        return fs.readFileSync(historyPath, 'utf8');
    } catch {
        return 'Burnley history is temporarily unavailable.';
    }
}

function formatFixtureList(): string {
    return fixtures
        .map((f) => `${f.id}: ${f.date} | ${f.competition} | ${f.home} vs ${f.away} | ${f.venue} | Tickets: ${f.ticketsAvailable}`)
        .join('\n');
}

function normalizeCategory(input?: string): ProductCategory | undefined {
    if (!input) {
        return undefined;
    }

    const key = input.trim().toLowerCase().replace(/_/g, '-') as ProductCategory;
    return supportedCategories.includes(key) ? key : undefined;
}

function findCaseInsensitiveKey(record: Record<string, number>, key: string): string | undefined {
    const target = key.trim().toLowerCase();
    return Object.keys(record).find((existingKey) => existingKey.toLowerCase() === target);
}

function findCaseInsensitiveNestedKey(record: Record<string, Record<string, number>>, key: string): string | undefined {
    const target = key.trim().toLowerCase();
    return Object.keys(record).find((existingKey) => existingKey.toLowerCase() === target);
}

export function registerBurnleyMcpTools(server: McpServer): void {
    server.registerTool(
        'fixture-list',
        {
            description: 'Manage Burnley fixtures and ticketing (list, book, cancel).',
            inputSchema: z.object({
                action: z.enum(['list', 'book', 'cancel']),
                fixtureId: z.string().optional(),
                customerName: z.string().optional(),
                quantity: z.number().int().positive().optional(),
                bookingId: z.string().optional()
            })
        },
        async ({ action, fixtureId, customerName, quantity, bookingId }: { action: 'list' | 'book' | 'cancel'; fixtureId?: string; customerName?: string; quantity?: number; bookingId?: string }) => {
            if (action === 'list') {
                return {
                    content: [
                        {
                            type: 'text' as const,
                            text: `Upcoming Burnley fixtures:\n${formatFixtureList()}`
                        }
                    ]
                };
            }

            if (action === 'book') {
                if (!fixtureId || !customerName || !quantity) {
                    return {
                        content: [{ type: 'text' as const, text: 'Booking requires fixtureId, customerName and quantity.' }]
                    };
                }

                const fixture = fixtures.find((f) => f.id === fixtureId);
                if (!fixture) {
                    return {
                        content: [{ type: 'text' as const, text: `No fixture found for id ${fixtureId}.` }]
                    };
                }

                if (quantity > fixture.ticketsAvailable) {
                    return {
                        content: [{ type: 'text' as const, text: `Only ${fixture.ticketsAvailable} tickets are available for ${fixtureId}.` }]
                    };
                }

                fixture.ticketsAvailable -= quantity;
                const newBookingId = `BKG-${Date.now().toString(36).toUpperCase()}`;
                ticketBookings.set(newBookingId, { fixtureId, customerName, quantity });

                return {
                    content: [
                        {
                            type: 'text' as const,
                            text: `Booked ${quantity} ticket(s) for ${customerName}. Booking ID: ${newBookingId}.`
                        }
                    ]
                };
            }

            if (!bookingId) {
                return {
                    content: [{ type: 'text' as const, text: 'Cancellation requires bookingId.' }]
                };
            }

            const existingBooking = ticketBookings.get(bookingId);
            if (!existingBooking) {
                return {
                    content: [{ type: 'text' as const, text: `No booking found for id ${bookingId}.` }]
                };
            }

            const fixture = fixtures.find((f) => f.id === existingBooking.fixtureId);
            if (fixture) {
                fixture.ticketsAvailable += existingBooking.quantity;
            }
            ticketBookings.delete(bookingId);

            return {
                content: [
                    {
                        type: 'text' as const,
                        text: `Booking ${bookingId} cancelled successfully.`
                    }
                ]
            };
        }
    );

    server.registerTool(
        'history',
        {
            description: 'Returns historical information about Burnley FC from a pre-canned history file.',
            inputSchema: z.object({
                topic: z.string().optional()
            })
        },
        async ({ topic }: { topic?: string }) => {
            const historyText = readHistoryText();
            const suffix = topic ? `\n\nRequested topic: ${topic}` : '';
            return {
                content: [
                    {
                        type: 'text' as const,
                        text: `${historyText}${suffix}`
                    }
                ]
            };
        }
    );

    server.registerTool(
        'shop-browse-products',
        {
            description: `Browse Burnley club shop products by category or search text. Supported categories: ${supportedCategories.join(', ')}.`,
            inputSchema: z.object({
                category: z.string().optional(),
                search: z.string().optional()
            })
        },
        async ({ category, search }: { category?: string; search?: string }) => {
            const normalizedCategory = normalizeCategory(category);
            const searchLower = search?.toLowerCase();
            const filtered = products.filter((p) => {
                const categoryMatch = normalizedCategory ? p.category === normalizedCategory : true;
                const searchMatch = searchLower ? p.name.toLowerCase().includes(searchLower) || p.sku.toLowerCase().includes(searchLower) : true;
                return categoryMatch && searchMatch;
            });

            if (filtered.length === 0) {
                return {
                    content: [{ type: 'text' as const, text: 'No products matched your filters.' }]
                };
            }

            const guidance = category && !normalizedCategory
                ? `Unrecognized category "${category}". Showing all categories. Supported values: ${supportedCategories.join(', ')}.\n`
                : '';

            const text = filtered
                .map((p) => `${p.sku} | ${p.name} | Category: ${p.category} | Price: GBP ${p.priceGbp}`)
                .join('\n');

            return {
                content: [
                    {
                        type: 'text' as const,
                        text: `${guidance}Burnley club-shop products:\n${text}`
                    }
                ]
            };
        }
    );

    server.registerTool(
        'shop-check-availability',
        {
            description: 'Check stock availability for product size and color combinations.',
            inputSchema: z.object({
                sku: z.string(),
                color: z.string(),
                size: z.string()
            })
        },
        async ({ sku, color, size }: { sku: string; color: string; size: string }) => {
            const product = products.find((p) => p.sku.toLowerCase() === sku.toLowerCase());
            if (!product) {
                return {
                    content: [{ type: 'text' as const, text: `No product found for SKU ${sku}.` }]
                };
            }

            const matchedColor = findCaseInsensitiveNestedKey(product.stockByColorAndSize, color);
            const colorStock = matchedColor ? product.stockByColorAndSize[matchedColor] : undefined;
            if (!colorStock) {
                return {
                    content: [{ type: 'text' as const, text: `Color ${color} is not offered for ${product.name}. Available colors: ${product.colors.join(', ')}.` }]
                };
            }

            const matchedSize = findCaseInsensitiveKey(colorStock, size);
            const units = matchedSize ? colorStock[matchedSize] ?? 0 : 0;
            if (units <= 0) {
                return {
                    content: [{ type: 'text' as const, text: `${product.name} is currently out of stock in ${matchedColor} / ${size}.` }]
                };
            }

            return {
                content: [{ type: 'text' as const, text: `${product.name} has ${units} unit(s) available in ${matchedColor} / ${matchedSize}.` }]
            };
        }
    );
}
