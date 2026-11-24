#include "solver.hpp"
#include <chrono>
namespace blacksmith {
double Context::get(const std::string &axis) const {
    if (axis == "temperature")
        return temperature;
    if (axis == "plastic_strain")
        return strain;
    if (extra) {
        auto it = extra->find(axis);
        if (it != extra->end())
            return it->second;
    }
    return std::numeric_limits<double>::quiet_NaN();
}
double Curve::tangent(size_t i, int lane) const {
    const size_t l = i ? i - 1 : 0, r = std::min(i + 1, times.size() - 1);
    auto v = [&](size_t k) { return values[k * width + lane]; };
    if (l == i || r == i)
        return (v(r) - v(l)) / (times[r] - times[l]);
    const double a = times[i] - times[l], b = times[r] - times[i];
    return (((v(i) - v(l)) / a) * b + ((v(r) - v(i)) / b) * a) / (a + b);
}
double Curve::eval(const Context &ctx, int lane) const {
    if (width == 1)
        lane = 0;
    double result = 0;
    if (kind == CONSTANT)
        return values[lane];
    if (kind == KEYS) {
        const double x = ctx.get(axis);
        if (!std::isfinite(x))
            return x;
        if (x <= times.front())
            return values[lane];
        if (x >= times.back())
            return values[(times.size() - 1) * width + lane];
        const size_t hi = std::upper_bound(times.begin(), times.end(), x) - times.begin(),
                     lo = hi - 1;
        const double a = values[lo * width + lane], b = values[hi * width + lane];
        if (interpolation == STEP)
            return a;
        const double span = times[hi] - times[lo], t = (x - times[lo]) / span;
        if (interpolation == LINEAR)
            result = a + (b - a) * t;
        else {
            const double t2 = t * t, t3 = t2 * t;
            result = (2 * t3 - 3 * t2 + 1) * a + (t3 - 2 * t2 + t) * span * tangent(lo, lane) +
                     (-2 * t3 + 3 * t2) * b + (t3 - t2) * span * tangent(hi, lane);
        }
    } else {
        result = inputs.front()->eval(ctx, lane);
        for (size_t i = 1; i < inputs.size(); ++i) {
            const double b = inputs[i]->eval(ctx, lane);
            if (!std::isfinite(result) || !std::isfinite(b))
                return std::numeric_limits<double>::quiet_NaN();
            switch (kind) {
            case ADD:
                result += b;
                break;
            case MULTIPLY:
                result *= b;
                break;
            case MINIMUM:
                result = std::min(result, b);
                break;
            case MAXIMUM:
                result = std::max(result, b);
                break;
            default:
                break;
            }
        }
    }
    return std::isfinite(result) ? result : std::numeric_limits<double>::quiet_NaN();
}
void Phase::index() {
    const char *names[] = {"youngs_modulus", "yield_strength", "ductility", "bulk_modulus"};
    for (int i = 0; i < 4; ++i) {
        auto it = curves.find(names[i]);
        mechanical[i] = it == curves.end() ? nullptr : it->second.get();
        if (mechanical[i])
            strain_dependent = strain_dependent || mechanical[i]->strain_dependent;
    }
}
const Phase *Material::phase(double temperature) const {
    const Phase *selected = phases.empty() ? nullptr : &phases.front();
    for (const auto &p : phases) {
        if (p.temperature > temperature)
            break;
        selected = &p;
    }
    return selected;
}
bool Material::properties(double temperature, double strain, bool bulk,
                          std::array<double, 4> &out) {
    const auto *p = phase(temperature);
    if (!p)
        return false;
    if (last_temperature == temperature && last_bulk == bulk &&
        (!p->strain_dependent || last_strain == strain)) {
        out = cached;
        return true;
    }
    out = {};
    Context context{temperature, strain, nullptr};
    for (int i = 0; i < (bulk ? 4 : 3); ++i) {
        if (!p->mechanical[i] || p->mechanical[i]->width != 1 || p->mechanical[i]->vector)
            return false;
        out[i] = p->mechanical[i]->eval(context);
        if (!std::isfinite(out[i]) || out[i] < 0)
            return false;
    }
    cached = out;
    last_temperature = temperature;
    last_strain = strain;
    last_bulk = bulk;
    return true;
}
bool Parameters::valid() const {
    return std::isfinite(minimum_step) && minimum_step > 0 && std::isfinite(maximum_step) &&
           maximum_step >= minimum_step && std::isfinite(minimum_length) && minimum_length > 0 &&
           std::isfinite(anvil) && std::isfinite(anvil_friction) && anvil_friction >= 0 &&
           gravity.finite() && substeps > 0 && iterations > 0 &&
           std::isfinite(transfer) && transfer >= 0 && transfer <= 1 && std::isfinite(depth) &&
           depth >= 0 && std::isfinite(tolerance) && tolerance >= 0;
}
template <typename Point>
static Volume cell_volume(const std::vector<Point> &nodes, const Cell &cell) {
    // The six tetrahedra share diagonal d=(p7-p0). Their signed volume is
    // dot(d, area)/6, where area is the closed ring 1,3,2,6,4,5's vector area.
    // In a four-triangle fan, each adjacent pair shares a ray. Combine
    // their cross products before evaluating the area. Ring gradients
    // are cross(next-previous,d)/6.
    static constexpr int ids[6] = {1, 3, 2, 6, 4, 5};
    std::array<V, 6> ring;
    for (int i = 0; i < 6; ++i)
        ring[i] = nodes[cell.nodes[ids[i]]].position;
    const V diagonal = nodes[cell.nodes[7]].position - nodes[cell.nodes[0]].position;
    const V area = (ring[1] - ring[3]).cross(ring[2] - ring[0]) +
                   (ring[3] - ring[5]).cross(ring[4] - ring[0]);
    Volume out;
    out.value = diagonal.dot(area) / 6.0;
    out.gradient[7] = area / 6.0;
    V sum = out.gradient[7];
    for (int i = 0; i < 6; ++i) {
        out.gradient[ids[i]] = (ring[(i + 1) % 6] - ring[(i + 5) % 6]).cross(diagonal) / 6.0;
        sum += out.gradient[ids[i]];
    }
    out.gradient[0] = -sum;
    return out;
}

Volume volume(const std::vector<Node> &nodes, const Cell &cell) {
    return cell_volume(nodes, cell);
}

template <typename Point>
static void project_anvil(std::vector<Point> &nodes, double anvil, double h,
                          std::vector<double> &support) {
    for (size_t i = 0; i < nodes.size(); ++i) {
        auto &n = nodes[i];
        if (n.position.y < anvil) {
            const double correction = (anvil - n.position.y) / h;
            n.velocity.y += correction;
            n.position.y = static_cast<float>(anvil);
            if (!support.empty())
                support[i] += correction;
        }
    }
}

bool Solver::step(double dt) {
    error.clear();
    using Clock = std::chrono::steady_clock;
    profile_usec.fill(0);
    auto now = [&]() { return profiling ? Clock::now() : Clock::time_point{}; };
    auto record = [&](size_t phase, Clock::time_point start) {
        if (profiling)
            profile_usec[phase] +=
                std::chrono::duration<double, std::micro>(Clock::now() - start).count();
    };
    auto phase_start = now();
    if (!parameters.valid() || !std::isfinite(dt) || dt < parameters.minimum_step ||
        dt > parameters.maximum_step) {
        error = "Invalid timestep or native parameters.";
        return false;
    }
    for (const auto &n : state.nodes) {
        if (!n.position.finite() || !n.velocity.finite() || !n.orientation.finite() ||
            n.orientation.determinant() <= 0 || !std::isfinite(n.mass) || n.mass <= 0 ||
            !std::isfinite(n.temperature) || !std::isfinite(n.strain) || n.strain < 0 ||
            n.material < 0 || size_t(n.material) >= materials.size()) {
            error = "Invalid native node state.";
            return false;
        }
    }
    for (const auto &l : state.links) {
        if (l.a < 0 || l.b < 0 || l.a == l.b || size_t(l.a) >= state.nodes.size() ||
            size_t(l.b) >= state.nodes.size() || !std::isfinite(l.rest) || l.rest <= 0 ||
            !std::isfinite(l.initial) || l.initial <= 0 || !std::isfinite(l.area) || l.area <= 0 ||
            !std::isfinite(l.damping) || l.damping < 0 || !std::isfinite(l.damage) ||
            l.damage < 0 || (!l.broken && l.damage >= 1) || !l.direction.finite()) {
            error = "Invalid native connection state.";
            return false;
        }
    }
    for (const auto &c : state.cells) {
        if (!std::isfinite(c.rest) || c.rest <= 0) {
            error = "Invalid native cell volume.";
            return false;
        }
        for (int id : c.nodes)
            if (id < 0 || size_t(id) >= state.nodes.size()) {
                error = "Invalid native cell node.";
                return false;
            }
        for (int id : c.edges)
            if (id < 0 || size_t(id) >= state.links.size()) {
                error = "Invalid native cell edge.";
                return false;
            }
    }
    work = state;
    for (auto &n : work.nodes) {
        n.increment = 0;
        n.spreading = 0;
        n.inverse_mass = 1 / n.mass;
    }
    for (auto &l : work.links)
        l.stiffness = 0;
    properties.resize(work.nodes.size());
    const double h = dt / parameters.substeps;
    const float inverse_h = 1.0f / static_cast<float>(h);
    projection_points.resize(work.nodes.size());
    record(0, phase_start);
    for (int substep = 0; substep < parameters.substeps; ++substep) {
        phase_start = now();
        anvil_support.assign(parameters.anvil_friction > 0 ? work.nodes.size() : 0, 0);
        for (size_t i = 0; i < work.nodes.size(); ++i) {
            auto &n = work.nodes[i];
            if (!materials[n.material].properties(n.temperature, n.strain, !work.cells.empty(),
                                                  properties[i])) {
                error = "Invalid or unavailable native material curve response.";
                return false;
            }
            n.position += n.velocity * h;
        }
        project_anvil(work.nodes, parameters.anvil, h, anvil_support);
        record(1, phase_start);
        phase_start = now();
        plasticity();
        // Resolve body-force prediction elastically before the next plastic trial.
        for (auto &n : work.nodes) {
            n.velocity += parameters.gravity * h;
            n.position += parameters.gravity * h * h;
        }
        project_anvil(work.nodes, parameters.anvil, h, anvil_support);
        lambdas.assign(work.links.size(), 0);
        volume_lambdas.assign(work.cells.size(), 0);
        // Compliance and inverse masses do not vary during projection iterations.
        for (auto &l : work.links)
            if (!l.broken && l.stiffness > 0) {
                l.alpha = 1 / (l.stiffness * h * h);
                l.inverse_denominator =
                    1 / (work.nodes[l.a].inverse_mass + work.nodes[l.b].inverse_mass + l.alpha);
            }
        for (auto &c : work.cells) {
            c.active = true;
            for (int edge : c.edges)
                if (work.links[edge].broken)
                    c.active = false;
            double bulk = std::numeric_limits<double>::infinity();
            for (int id : c.nodes)
                bulk = std::min(bulk, properties[id][3]);
            c.constrained = bulk > 0;
            c.alpha = c.constrained ? c.rest / (bulk * h * h) : 0;
        }
        // Keep projection iterations in a compact working set. Each correction
        // still updates positions and velocities in the original solver order.
        for (size_t i = 0; i < work.nodes.size(); ++i) {
            const auto &n = work.nodes[i];
            projection_points[i] = {n.position, n.velocity, n.inverse_mass};
        }
        record(2, phase_start);
        for (int iteration = 0; iteration < parameters.iterations; ++iteration) {
            phase_start = now();
            solve_links(inverse_h);
            record(3, phase_start);
            phase_start = now();
            solve_volumes(inverse_h);
            record(4, phase_start);
            phase_start = now();
            project_anvil(projection_points, parameters.anvil, h, anvil_support);
            record(5, phase_start);
        }
        phase_start = now();
        for (size_t i = 0; i < work.nodes.size(); ++i) {
            work.nodes[i].position = projection_points[i].position;
            work.nodes[i].velocity = projection_points[i].velocity;
        }
        damp(h);
        for (size_t i = 0; i < work.nodes.size(); ++i) {
            auto &n = work.nodes[i];
            if (n.position.y <= parameters.anvil && n.velocity.y < 0) {
                if (!anvil_support.empty())
                    anvil_support[i] -= n.velocity.y;
                n.velocity.y = 0;
            }
            if (!anvil_support.empty() && anvil_support[i] > 0) {
                const V tangent{n.velocity.x, 0, n.velocity.z};
                const double speed = tangent.length();
                if (speed > 0) {
                    // Coulomb budget in velocity units. Friction cannot reverse slip.
                    const V reduced = tangent * std::max(0.0, 1 - parameters.anvil_friction * anvil_support[i] / speed);
                    n.velocity.x = reduced.x;
                    n.velocity.z = reduced.z;
                }
            }
        }
        record(5, phase_start);
    }
    phase_start = now();
    orientations();
    record(6, phase_start);
    for (const auto &n : work.nodes)
        if (!n.position.finite() || !n.velocity.finite() || !std::isfinite(n.strain) ||
            !n.orientation.finite()) {
            error = "Non-finite native result; prior state retained.";
            return false;
        }
    for (const auto &l : work.links)
        if (!std::isfinite(l.rest) || !std::isfinite(l.damage) || !std::isfinite(l.stiffness)) {
            error = "Non-finite native connection result; prior state retained.";
            return false;
        }
    std::swap(state, work);
    return true;
}
void Solver::plasticity() {
    const auto count = work.nodes.size();
    weights.assign(count, 0);
    changes.assign(count, 0);
    spreads.assign(count, 0);
    for (auto &l : work.links) {
        if (l.broken)
            continue;
        const double e = std::min(properties[l.a][0], properties[l.b][0]);
        const double yield = std::min(properties[l.a][1], properties[l.b][1]);
        const double ductility = std::min(properties[l.a][2], properties[l.b][2]);
        if (e == 0) {
            l.stiffness = 0;
            continue;
        }
        const double length =
            std::max<double>((work.nodes[l.b].position - work.nodes[l.a].position).length(),
                             parameters.minimum_length);
        const double strain = (length - l.rest) / l.rest, ys = yield / e;
        double increment = 0, extension = 0;
        if (std::abs(strain) > ys) {
            const double target = length / (1 + (strain > 0 ? 1 : -1) * ys);
            increment = std::abs(target - l.rest) / l.initial;
            const double trial = ductility == 0 ? 1 : l.damage + increment / ductility;
            l.damage = std::min(trial, 1.0);
            if (trial >= 1) {
                l.broken = true;
                l.stiffness = 0;
                continue;
            }
            extension = std::max(target - l.rest, 0.0) / l.initial;
            l.rest = std::max(target, parameters.minimum_length);
        }
        l.stiffness = e * l.area / l.rest;
        const double w = l.area * l.initial;
        for (int id : {l.a, l.b}) {
            weights[id] += w;
            changes[id] += increment * w;
            spreads[id] += extension * w;
        }
    }
    for (size_t i = 0; i < count; ++i)
        if (weights[i] > 0) {
            const double increment = changes[i] / weights[i];
            work.nodes[i].strain += increment;
            work.nodes[i].increment += increment;
            work.nodes[i].spreading += spreads[i] / weights[i];
        }
}
void Solver::solve_links(float inverse_h) {
    for (size_t i = 0; i < work.links.size(); ++i) {
        const auto &l = work.links[i];
        if (l.broken || l.stiffness == 0)
            continue;
        auto &a = projection_points[l.a];
        auto &b = projection_points[l.b];
        const V delta = b.position - a.position;
        const double length = delta.length();
        const V direction = length > parameters.minimum_length ? delta / length : l.direction;
        const double wa = a.inverse_mass, wb = b.inverse_mass;
        const double change = (-(length - l.rest) - l.alpha * lambdas[i]) * l.inverse_denominator;
        const V ca = direction * wa * change, cb = direction * wb * change;
        a.position -= ca;
        b.position += cb;
        a.velocity -= ca * inverse_h;
        b.velocity += cb * inverse_h;
        lambdas[i] += change;
    }
}
void Solver::solve_volumes(float inverse_h) {
    for (size_t i = 0; i < work.cells.size(); ++i) {
        const auto &c = work.cells[i];
        if (!c.active || !c.constrained)
            continue;
        const auto v = cell_volume(projection_points, c);
        const double alpha = c.alpha;
        double denominator = alpha;
        for (int j = 0; j < 8; ++j)
            denominator += v.gradient[j].dot(v.gradient[j]) * projection_points[c.nodes[j]].inverse_mass;
        if (denominator == 0)
            continue;
        const double change = (-(v.value - c.rest) - alpha * volume_lambdas[i]) / denominator;
        for (int j = 0; j < 8; ++j) {
            auto &n = projection_points[c.nodes[j]];
            const V correction = v.gradient[j] * (change * n.inverse_mass);
            n.position += correction;
            n.velocity += correction * inverse_h;
        }
        volume_lambdas[i] += change;
    }
}
void Solver::damp(double h) {
    for (const auto &l : work.links) {
        if (l.broken)
            continue;
        auto &a = work.nodes[l.a];
        auto &b = work.nodes[l.b];
        const V delta = b.position - a.position;
        if (delta.length() <= parameters.minimum_length)
            continue;
        const V direction = delta.normalized();
        const double relative = (b.velocity - a.velocity).dot(direction), wa = a.inverse_mass,
                     wb = b.inverse_mass;
        const double impulse = l.damping * h * relative / (1 + l.damping * h * (wa + wb));
        a.velocity += direction * impulse * wa;
        b.velocity -= direction * impulse * wb;
    }
}
void Solver::orientations() {
    std::vector<V> x(work.nodes.size()), y(work.nodes.size()), z(work.nodes.size());
    for (const auto &c : work.cells)
        if (c.active) {
            V a, b, d;
            for (int i : {0, 2, 4, 6})
                a += work.nodes[c.nodes[i + 1]].position - work.nodes[c.nodes[i]].position;
            for (int i : {0, 1, 4, 5})
                b += work.nodes[c.nodes[i + 2]].position - work.nodes[c.nodes[i]].position;
            for (int i : {0, 1, 2, 3})
                d += work.nodes[c.nodes[i + 4]].position - work.nodes[c.nodes[i]].position;
            for (int id : c.nodes) {
                x[id] += a;
                y[id] += b;
                z[id] += d;
            }
        }
    for (size_t i = 0; i < work.nodes.size(); ++i) {
        B b{x[i], y[i], z[i]};
        if (b.finite() && b.determinant() > 0) {
            B candidate = b.orthonormal() * work.nodes[i].reference_orientation;
            if (candidate.finite() && candidate.determinant() > 0)
                work.nodes[i].orientation = candidate;
        }
    }
}
bool Solver::hammer(V center, V normal, double radius, double mass, V velocity) {
    last_impulse = {};
    error.clear();
    if (!parameters.valid() || !center.finite() || !normal.finite() || !velocity.finite() ||
        normal.length() == 0 || !std::isfinite(radius) || radius <= 0 || !std::isfinite(mass) ||
        mass <= 0) {
        error = "Invalid native hammer input.";
        return false;
    }
    const V direction = normal.normalized();
    std::vector<size_t> candidates;
    std::vector<double> depths;
    double front = -std::numeric_limits<double>::infinity();
    for (size_t i = 0; i < state.nodes.size(); ++i) {
        const auto &n = state.nodes[i];
        if (!n.position.finite() || !n.velocity.finite() || !std::isfinite(n.mass) || n.mass <= 0)
            return false;
        const V offset = n.position - center;
        const double depth = offset.dot(direction);
        const V lateral = offset - direction * depth;
        if (depth <= parameters.tolerance && depth >= -parameters.depth &&
            lateral.dot(lateral) <= radius * radius) {
            candidates.push_back(i);
            depths.push_back(depth);
            front = std::max(front, depth);
        }
    }
    std::vector<size_t> contact;
    double total = 0;
    V momentum;
    for (size_t i = 0; i < candidates.size(); ++i)
        if (front - depths[i] <= parameters.tolerance) {
            const auto id = candidates[i];
            contact.push_back(id);
            total += state.nodes[id].mass;
            momentum += state.nodes[id].velocity * state.nodes[id].mass;
        }
    if (contact.empty() || !std::isfinite(total))
        return false;
    const double speed = (velocity - momentum / total).dot(direction);
    if (speed >= 0)
        return false;
    const double effective = 1 / (1 / mass + 1 / total);
    const V impulse = direction * speed * effective * parameters.transfer, change = impulse / total;
    for (size_t id : contact)
        if (!(state.nodes[id].velocity + change).finite())
            return false;
    for (size_t id : contact)
        state.nodes[id].velocity += change;
    last_impulse = impulse;
    return true;
}
double Solver::total_mass() const {
    double sum = state.discarded_mass;
    for (const auto &n : state.nodes)
        sum += n.mass;
    return sum;
}
} // namespace blacksmith
