// This file calls our main function. It contains all OpenGL source code. It has an object of
// Game_Of_Life which it uses to determine the color of squares.

#include <stdbool.h>
#include <stdio.h>
#include <GL/glew.h>
#include <GL/freeglut.h>

#define WIDTH 1024
#define HEIGHT 768
#define NUM_SPECIES 10

enum Species { S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, DEAD };
static const enum Species species_map[] = { S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, DEAD };

enum Species *grid;

void set_cell(int x, int y, enum Species s) {
    int index = WIDTH * y + x;
    grid[index] = s;
}

enum Species get_cell(int x, int y) {
    int index = WIDTH * y + x;
    return grid[index];
}

void initialize_grid() {
    srand(time(NULL));
    grid = (enum Species*) malloc(WIDTH * HEIGHT * sizeof(enum Species));

    for (int i = 0; i < HEIGHT; i++) {
        for (int j = 0; j < WIDTH; j++) {
            set_cell(j, i, DEAD);
        }
    }

    for (int i = 0; i < NUM_SPECIES; i++) {
        enum Species species = species_map[i];

        int square_size = WIDTH * .10;

        // fill ~20% of square
        int number_of_squares = (int) floor((square_size * square_size) * 0.20);
        int distance_from_edge = square_size + 2;

        // choose random target on board, at least specified distance from edges
        int x_target = (rand() % (WIDTH - (distance_from_edge * 2 - 1))) + distance_from_edge;
        int y_target = (rand() % (HEIGHT - (distance_from_edge * 2 - 1))) + distance_from_edge;

        set_cell(x_target, y_target, species);

        // pick number_of_squares within (square_size x square_size) square centered on target
        int rand_x;
        int rand_y;
        for (int i = 0; i < number_of_squares; i++) {
            rand_x = x_target + ((rand() % (square_size + 1)) - (square_size/2));
            rand_y = y_target + ((rand() % (square_size + 1)) - (square_size/2));
            set_cell(rand_x, rand_y, species);
        }
    }
}

__device__ void set_d_cell(int idx, enum Species s, enum Species *grid_d) {
    grid_d[idx] = s;
}

__device__ enum Species get_d_cell(int idx, enum Species *grid_d) {
    return grid_d[idx];
}

__device__ enum Species get_d_cell(int x, int y, enum Species *grid_d) {
    int idx = y * 1024 + x;
    return grid_d[idx];
}

__device__ int number_of_neighbors(int idx, enum Species s, enum Species *grid_d) {
    int count = 0;

    int x = idx % 1024;
    int y = idx / 1024;

    // iterate over 3x3 grid centered on (x,y)
    for (int i = x - 1; i <= x + 1; i++) {
        for (int j = y - 1; j <= y + 1; j++) {
            // check only if cell isn't current cell (x,y) AND cell is not out of bounds
            if ((i != x || j != y) && (i >= 0 && j >= 0 && i < 1024 && j < 768)) {
                if (get_d_cell(i, j, grid_d) == s) {
                    count++;
                }
            }
        }
    }

    return count;
}

__device__ bool has_three_neighbors(int idx, enum Species *grid_d) {
    int count = 0;

    int x = idx % 1024;
    int y = idx / 1024;

    for (int i = x - 1; i <= x + 1; i++) {
        for (int j = y - 1; j <= y + 1; j++) {
            // check only if cell isn't current cell (x,y) AND cell is not out of bounds
            if ((i != x || j != y) && (i >= 0 && j >= 0 && i < WIDTH && j < HEIGHT)) {
                if (get_d_cell(i, j, grid_d) != DEAD) {
                    if (++count == 3) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

__global__ void kernel(enum Species *grid_d, enum Species *species_map_d, enum Species *update_list_d) {

    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < WIDTH * HEIGHT) {

        // determine species of cell
        enum Species species = get_d_cell(idx, grid_d);

        // if species lives in cell, count # neighbors and add to kill list if applicable
        if (species != DEAD) {
            int num_neighbors = number_of_neighbors(idx, species, grid_d);
            if (num_neighbors < 2 || num_neighbors > 3) {
                set_d_cell(idx, DEAD, update_list_d);
            }
        // if no species in cell, check if any species should be spawned there
        // do "heavier" get_spawn_type() only if 3 neighbors exist
        } else if (has_three_neighbors(idx, grid_d)) {
            for (int i = 0; i < 10; i++) {
                enum Species s = species_map_d[i];
                int num_neighbors = number_of_neighbors(idx, s, grid_d);
                if (s != DEAD && num_neighbors == 3) {
                    set_d_cell(idx, s, update_list_d);
                }
            }
        }
    }
}

void update_grid() {

    enum Species *grid_d;
    enum Species *update_list_d;
    enum Species *species_map_d;

    int grid_size = WIDTH * HEIGHT * sizeof(enum Species);
    int map_size = sizeof(species_map);
    cudaMalloc((void **) &grid_d, grid_size);
    cudaMalloc((void **) &update_list_d, grid_size);
    cudaMalloc((void **) &species_map_d, map_size);
    cudaMemcpy(grid_d, grid, grid_size, cudaMemcpyHostToDevice);
    cudaMemcpy(update_list_d, grid, grid_size, cudaMemcpyHostToDevice);
    cudaMemcpy(species_map_d, species_map, map_size, cudaMemcpyHostToDevice);

    int block_size = 512;
    dim3 dimBlock(block_size);
    dim3 dimGrid(ceil(WIDTH * HEIGHT / (float) block_size));

    kernel<<<dimGrid, dimBlock>>>(grid_d, species_map_d, update_list_d);
    grid_d = update_list_d;

    cudaMemcpy(grid, grid_d, grid_size, cudaMemcpyDeviceToHost);
    cudaFree(grid_d);
}

// sets the color that OpenGL will draw with
void set_color(enum Species species) {
    switch(species) {
        case S0:	glColor3f(1.0f, 0.0f, 0.0f); break; // RED
        case S1:	glColor3f(0.0f, 1.0f, 0.0f); break; // GREEN
        case S2:	glColor3f(0.1f, 0.2f, 1.0f); break; // BLUE
        case S3:	glColor3f(1.0f, 1.0f, 0.0f); break; // YELLOW
        case S4:	glColor3f(1.0f, 0.0f, 1.0f); break; // MAGENTA
        case S5:	glColor3f(0.0f, 1.0f, 1.0f); break; // CYAN
        case S6:	glColor3f(1.0f, 1.0f, 1.0f); break; // WHITE
        case S7:	glColor3f(1.0f, 0.5f, 0.0f); break; // ORANGE
        case S8:	glColor3f(0.5f, 0.5f, 0.5f); break; // GREY
        case S9:	glColor3f(0.4f, 0.0f, 1.0f); break; // VIOLET
        default:	glColor3f(0.0f, 0.0f, 0.0f);		// BLACK
    }
}

// places a square at (x, y). Must be nested in glBegin() <-> glEnd() tags
void draw_square(int x, int y) {
    if (x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT) {
        printf("Invalid range in draw_square. (%d, %d) out of range", x, y);
        exit(1);
    }

    glVertex2f(x, y);
    glVertex2f(x + 1, y);
    glVertex2f(x + 1, y + 1);
    glVertex2f(x, y + 1);
}

void draw_board() {
    glBegin(GL_QUADS);
    for (int i = 0; i < HEIGHT; i++) {
        for (int j = 0; j < WIDTH; j++) {
            enum Species s = get_cell(j, i);
            set_color(s);
            draw_square(j, i);
        }
    }
    glEnd();
    glFlush();
}

// infinite loop. It fetches and operates on the cells that need to be changed forever
void display() {
    initialize_grid();
    draw_board();

    int count = 0;
    clock_t start = clock();

    for(;;) {
        update_grid();
        draw_board();

        count++;
        double duration = double(clock() - start) / CLOCKS_PER_SEC;
        if (duration > 2) {
            printf("FPS = %.2f\n", count/duration);
            start = clock();
            count = 0;
        }
    }
}

// intializate OpenGL and begin our display loop
int main(int argc, char **argv) {
    glutInit(&argc, argv);
    glutInitDisplayMode(GLUT_SINGLE | GLUT_RGB | GLUT_DEPTH);

    glutInitWindowSize(WIDTH, HEIGHT);
    glutCreateWindow("Game of Life 2.1");

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0.0f, WIDTH, HEIGHT, 0.0f, -1.0f, 1.0f);

    glutDisplayFunc(display);

    glutMainLoop();

    free(grid);
}
