#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace blacksmith {
struct V {
    float x = 0, y = 0, z = 0;
    V() = default;
    V(float a, float b, float c) : x(a), y(b), z(c) {}
    V operator+(V b) const { return {x + b.x, y + b.y, z + b.z}; }
    V operator-(V b) const { return {x - b.x, y - b.y, z - b.z}; }
    V operator-() const { return {-x, -y, -z}; }
    V operator*(double b) const {
        float s = static_cast<float>(b);
        return {x * s, y * s, z * s};
    }
    V operator/(double b) const { return *this * (1.0f / static_cast<float>(b)); }
    V &operator+=(V b) { return *this = *this + b; }
    V &operator-=(V b) { return *this = *this - b; }
    float dot(V b) const { return x * b.x + y * b.y + z * b.z; }
    V cross(V b) const { return {y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x}; }
    float length() const { return std::sqrt(dot(*this)); }
    V normalized() const {
        auto l = length();
        return l > 0 ? *this / l : V{};
    }
    bool finite() const { return std::isfinite(x) && std::isfinite(y) && std::isfinite(z); }
};
struct B {
    V x{1, 0, 0}, y{0, 1, 0}, z{0, 0, 1};
    V apply(V a) const { return x * a.x + y * a.y + z * a.z; }
    B operator*(const B &b) const { return {apply(b.x), apply(b.y), apply(b.z)}; }
    double determinant() const { return x.dot(y.cross(z)); }
    bool finite() const { return x.finite() && y.finite() && z.finite(); }
    B orthonormal() const {
        B b = *this;
        b.x = b.x.normalized();
        b.y = (b.y - b.x * b.x.dot(b.y)).normalized();
        b.z = (b.z - b.x * b.x.dot(b.z) - b.y * b.y.dot(b.z)).normalized();
        return b;
    }
};
struct Context {
    double temperature = 0, strain = 0;
    const std::map<std::string, double> *extra = nullptr;
    double get(const std::string &axis) const;
};
struct Curve {
    enum Kind { CONSTANT, KEYS, ADD, MULTIPLY, MINIMUM, MAXIMUM } kind = CONSTANT;
    enum Interpolation { LINEAR, STEP, CUBIC } interpolation = LINEAR;
    std::string axis = "temperature";
    int width = 1;
    bool vector = false, strain_dependent = false;
    std::vector<double> times, values{0};
    std::vector<std::shared_ptr<Curve>> inputs;
    double eval(const Context &, int lane = 0) const;
    double tangent(size_t index, int lane) const;
};
using Curves = std::map<std::string, std::shared_ptr<Curve>>;
struct Phase {
    double temperature = -std::numeric_limits<double>::infinity();
    Curves curves;
    std::array<const Curve *, 4> mechanical{};
    bool strain_dependent = false;
    void index();
};
struct Material {
    std::vector<Phase> phases;
    double last_temperature = std::numeric_limits<double>::quiet_NaN(), last_strain = 0;
    bool last_bulk = false;
    std::array<double, 4> cached{};
    bool properties(double temperature, double strain, bool bulk, std::array<double, 4> &out);
    const Phase *phase(double temperature) const;
};
struct Node {
    V position, velocity;
    B orientation, reference_orientation;
    double mass = 0, temperature = 0, strain = 0, increment = 0, spreading = 0, inverse_mass = 0;
    int material = -1;
};
struct Link {
    int a = 0, b = 0;
    double rest = 0, initial = 0, area = 0, damping = 0, stiffness = 0, damage = 0, alpha = 0,
           inverse_denominator = 0;
    V direction{1, 0, 0};
    bool broken = false;
};
struct Cell {
    std::array<int, 8> nodes{};
    std::array<int, 12> edges{};
    double rest = 0, alpha = 0;
    bool active = true, constrained = true;
};
struct State {
    std::vector<Node> nodes;
    std::vector<Link> links;
    std::vector<Cell> cells;
    double discarded_mass = 0;
};
struct Parameters {
    double minimum_step = 0, maximum_step = 0, minimum_length = 0, anvil = 0;
    double transfer = 0, depth = 0, tolerance = 0;
    int substeps = 0, iterations = 0;
    V gravity;
    double anvil_friction = 0, maximum_density_multiplier = 0;
    bool valid() const;
};
struct Volume {
    double value = 0;
    std::array<V, 8> gradient{};
};
Volume volume(const std::vector<Node> &nodes, const Cell &cell);
class Solver {
  public:
    State state;
    Parameters parameters;
    std::vector<Material> materials;
    std::string error;
    V last_impulse;
    bool profiling = false;
    std::array<double, 7> profile_usec{};
    bool step(double dt);
    bool hammer(V center, V normal, double radius, double mass, V velocity);
    double total_mass() const;

  private:
    struct ProjectionPoint {
        V position, velocity;
        double inverse_mass;
    };
    State work;
    std::vector<ProjectionPoint> projection_points;
    std::vector<int> components;
    std::vector<std::array<double, 4>> properties;
    std::vector<double> weights, changes, spreads, lambdas, volume_lambdas, anvil_support;
    void plasticity();
    void solve_links(float inverse_h);
    void solve_volumes(float inverse_h);
    void update_components();
    void limit_compression(float inverse_h);
    bool compression_resolved() const;
    void damp(double h);
    void orientations();
};
} // namespace blacksmith
