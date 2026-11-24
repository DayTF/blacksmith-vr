#include "solver.hpp"
#include <iostream>
using namespace blacksmith;
int failures = 0;
void expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << message << '\n';
        ++failures;
    }
}
std::shared_ptr<Curve> constant(double value) {
    auto c = std::make_shared<Curve>();
    c->values = {value};
    return c;
}
Solver pair(double ductility = 1) {
    Solver solver;
    solver.parameters = {1e-6, 1.0 / 30, 1e-8, 0, 1, 0.01, 1e-6, 4, 8, {}};
    Material m;
    Phase p;
    p.curves = {{"youngs_modulus", constant(100)},
                {"yield_strength", constant(10)},
                {"ductility", constant(ductility)}};
    p.index();
    m.phases.push_back(p);
    solver.materials.push_back(m);
    Node a, b;
    a.mass = b.mass = 1;
    a.temperature = b.temperature = 20;
    a.material = b.material = 0;
    a.position = {0, 1, 0};
    b.position = {1, 1, 0};
    solver.state.nodes = {a, b};
    Link l;
    l.rest = l.initial = l.area = 1;
    l.b = 1;
    l.damping = 0.1;
    solver.state.links.push_back(l);
    return solver;
}
int main() {
    auto elastic = pair();
    elastic.state.nodes[1].position.x = 1.05f;
    expect(elastic.step(0.01), "Elastic step failed");
    expect(elastic.state.nodes[0].velocity.x > 0 && elastic.state.nodes[1].velocity.x < 0,
           "Incorrect spring force direction");
    expect(std::abs(elastic.state.nodes[0].velocity.x + elastic.state.nodes[1].velocity.x) < 1e-5,
           "Internal momentum lost");
    expect(elastic.state.links[0].rest == 1, "Elastic rest length changed");
    auto plastic = pair();
    plastic.state.nodes[1].position.x = 1.3f;
    expect(plastic.step(0.001) && plastic.state.links[0].rest > 1 &&
               plastic.state.nodes[0].strain > 0,
           "Permanent yielding missing");
    expect(plastic.total_mass() == 2, "Mass changed");
    for (float position : {0.7f, 1.3f}) {
        auto brittle = pair(0.01);
        brittle.state.nodes[1].position.x = position;
        expect(brittle.step(0.001) && brittle.state.links[0].broken,
               "Compression/tension fracture missing");
        expect(brittle.state.links[0].rest == 1 && brittle.state.nodes[0].strain == 0,
               "Fracturing increment committed plasticity");
    }
    auto invalid = pair();
    auto original = invalid.state.nodes[0].position;
    expect(!invalid.step(1) && invalid.state.nodes[0].position.x == original.x,
           "Invalid timestep mutated state");
    invalid.materials[0].phases[0].curves["youngs_modulus"]->values[0] = -1;
    expect(!invalid.step(0.01), "Negative material response accepted");
    auto impact = pair();
    expect(impact.hammer({0, 1, 0}, {0, 1, 0}, 0.2, 2, {0, -1, 0}), "Hammer failed");
    expect(impact.state.nodes[0].velocity.y < 0 && impact.state.nodes[0].velocity.y > -1,
           "Unbounded contact speed");
    expect(std::abs(impact.state.nodes[0].velocity.y - impact.last_impulse.y) < 1e-6,
           "Contact momentum mismatch");
    Curve cubic;
    cubic.kind = Curve::KEYS;
    cubic.interpolation = Curve::CUBIC;
    cubic.times = {0, 1, 3, 4};
    cubic.values = {0, 1, 9, 16};
    expect(std::abs(cubic.eval({2, 0, nullptr}) - 4) < 1e-12,
           "Nonuniform cubic interpolation incorrect");
    expect(!std::isfinite(cubic.eval({std::numeric_limits<double>::quiet_NaN(), 0, nullptr})),
           "Invalid graph input accepted");
    State cube;
    for (int z = 0; z < 2; ++z)
        for (int y = 0; y < 2; ++y)
            for (int x = 0; x < 2; ++x) {
                Node n;
                n.position = {float(x), float(y), float(z)};
                cube.nodes.push_back(n);
            }
    Cell cell;
    cell.nodes = {0, 1, 2, 3, 4, 5, 6, 7};
    auto v = volume(cube.nodes, cell);
    V sum;
    expect(std::abs(v.value - 1) < 1e-6, "Cube volume incorrect");
    for (auto g : v.gradient)
        sum += g;
    expect(sum.length() < 1e-6, "Volume gradients violate translation invariance");
    // Independently cross-check the optimized identity against the original
    // six-tetrahedron reference on warped, non-planar cells.
    const int tetrahedra[6][4] = {{0, 1, 3, 7}, {0, 3, 2, 7}, {0, 2, 6, 7},
                                  {0, 6, 4, 7}, {0, 4, 5, 7}, {0, 5, 1, 7}};
    for (int sample = 0; sample < 20; ++sample) {
        State warped = cube;
        for (size_t i = 0; i < warped.nodes.size(); ++i)
            warped.nodes[i].position +=
                V{float(0.1 * std::sin(i + sample)), float(0.1 * std::cos(i * 2 + sample)),
                  float(0.1 * std::sin(i * 3 + sample))};
        Volume expected;
        for (const auto &t : tetrahedra) {
            V a = warped.nodes[t[1]].position - warped.nodes[t[0]].position;
            V b = warped.nodes[t[2]].position - warped.nodes[t[0]].position;
            V c = warped.nodes[t[3]].position - warped.nodes[t[0]].position;
            expected.value += a.dot(b.cross(c)) / 6.0;
            V g1 = b.cross(c) / 6.0, g2 = c.cross(a) / 6.0, g3 = a.cross(b) / 6.0;
            expected.gradient[t[0]] -= g1 + g2 + g3;
            expected.gradient[t[1]] += g1;
            expected.gradient[t[2]] += g2;
            expected.gradient[t[3]] += g3;
        }
        auto actual = volume(warped.nodes, cell);
        expect(std::abs(actual.value - expected.value) < 1e-6,
               "Optimized warped volume differs from reference");
        for (int i = 0; i < 8; ++i)
            expect((actual.gradient[i] - expected.gradient[i]).length() < 1e-6,
                   "Optimized warped gradient differs from reference");
    }
    std::cout << "Native invariant failures: " << failures << '\n';
    return failures ? 1 : 0;
}
